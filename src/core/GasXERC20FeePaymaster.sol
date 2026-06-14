// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BasePaymaster } from "@account-abstraction/contracts/core/BasePaymaster.sol";
import { UserOperationLib, PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { MultiOracleAggregator } from "../oracles/MultiOracleAggregator.sol";

/**
 * @title  GasX ERC20 Fee Paymaster
 * @author edsphinx
 * @notice A paymaster that sponsors gas fees in ETH and charges the user an equivalent fee in a specified ERC20 token (e.g., USDC).
 * @dev    This contract enables users to transact without holding the native gas token (ETH). It uses an off-chain
 * signature for real-time price data and an on-chain oracle for security verification. The token addresses
 * (for the fee and for pricing) are configured at deployment time, making the contract chain-agnostic.
 *
 * x402 Integration Ready: This paymaster can be used with x402 payment protocol for micropayments.
 */
contract GasXERC20FeePaymaster is BasePaymaster, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using UserOperationLib for PackedUserOperation;
    using SafeERC20 for IERC20;

    // --- State Variables ---

    /// @notice The ERC20 token used to pay fees (e.g., USDC).
    address public immutable feeToken;
    /// @notice The token used as the base for price quotes (e.g., WETH).
    address public immutable priceQuoteBaseToken;
    /// @notice The on-chain price oracle for ETH/FeeToken.
    MultiOracleAggregator public immutable priceOracle;
    /// @notice The address of the off-chain service authorized to sign prices.
    address public oracleSigner;

    /// @notice The maximum allowed deviation between the off-chain signed price and the on-chain oracle price.
    uint256 public constant PRICE_DEVIATION_BPS = 500; // 5%
    /// @notice Minimum fee in fee token units to cover operational costs (e.g., 0.01 USDC = 10000 for 6 decimals)
    uint256 public minFee;
    /// @notice Fee markup in basis points (e.g., 100 = 1% markup)
    uint256 public feeMarkupBps;
    /// @notice Total fees collected (for tracking)
    uint256 public totalFeesCollected;

    // --- Constants ---
    /// @dev PAYMASTER_DATA_OFFSET is inherited from BasePaymaster (52 bytes):
    ///      - Paymaster address: 20 bytes
    ///      - Validation gas limit (uint128): 16 bytes
    ///      - Post-op gas limit (uint128): 16 bytes
    uint256 private constant PRICE_SIZE = 32;
    uint256 private constant EXPIRY_SIZE = 6;

    // --- Events ---

    event OracleSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event FeeCharged(bytes32 indexed userOpHash, address indexed user, uint256 feeAmount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event MinFeeUpdated(uint256 previousMinFee, uint256 newMinFee);
    event FeeMarkupUpdated(uint256 previousMarkupBps, uint256 newMarkupBps);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    // Note: Paused and Unpaused events are inherited from Pausable

    // --- Constructor ---

    constructor(
        IEntryPoint _entryPoint,
        address _feeToken,
        address _priceQuoteBaseToken,
        address _priceOracle,
        address _initialOracleSigner,
        uint256 _minFee,
        uint256 _feeMarkupBps
    ) BasePaymaster(_entryPoint, msg.sender) {
        require(_feeToken != address(0), "GasX: Invalid feeToken address");
        require(_priceQuoteBaseToken != address(0), "GasX: Invalid priceQuoteBaseToken address");
        require(_priceOracle != address(0), "GasX: Invalid priceOracle address");
        require(_initialOracleSigner != address(0), "GasX: Invalid initialOracleSigner address");
        require(_feeMarkupBps <= 1000, "GasX: Markup too high"); // Max 10%
        // v0.9 BasePaymaster sets the owner via its constructor (Ownable2Step).
        feeToken = _feeToken;
        priceQuoteBaseToken = _priceQuoteBaseToken;
        priceOracle = MultiOracleAggregator(_priceOracle);
        oracleSigner = _initialOracleSigner;
        minFee = _minFee;
        feeMarkupBps = _feeMarkupBps;
    }

    // --- Validation Logic ---

    function _validatePaymasterUserOp(
        PackedUserOperation calldata op,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal view override whenNotPaused returns (bytes memory context, uint256 validationData) {
        // 1. Decode and verify off-chain data
        (uint256 offChainPrice, uint48 expiry, bytes memory signature) = _decodePaymasterData(op.paymasterAndData);
        require(block.timestamp < expiry, "GasX: Signature expired");

        // 2. Verify signature
        _verifySignature(userOpHash, offChainPrice, expiry, signature);

        // 3. Get and verify on-chain price
        uint256 onChainPrice = _verifyAndGetPrice(offChainPrice);

        // 4. Calculate and verify fee
        uint256 requiredFee = _calculateFee(maxCost, onChainPrice);
        _verifyUserFunds(op.sender, requiredFee);

        // 5. Pack context for postOp
        context = abi.encode(onChainPrice, op.sender, userOpHash);
        return (context, 0);
    }

    function _verifySignature(
        bytes32 userOpHash,
        uint256 offChainPrice,
        uint48 expiry,
        bytes memory signature
    ) internal view {
        bytes32 priceHash = keccak256(abi.encode(userOpHash, offChainPrice, expiry));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(priceHash);
        require(ECDSA.recover(ethSignedHash, signature) == oracleSigner, "GasX: Invalid signature");
    }

    function _verifyAndGetPrice(uint256 offChainPrice) internal view returns (uint256 onChainPrice) {
        onChainPrice = priceOracle.computeQuoteAverage(1e18, priceQuoteBaseToken, feeToken);
        require(onChainPrice > 0, "GasX: Invalid on-chain price");
        uint256 diff = onChainPrice > offChainPrice ? onChainPrice - offChainPrice : offChainPrice - onChainPrice;
        require((diff * 10_000) / onChainPrice <= PRICE_DEVIATION_BPS, "GasX: Price deviation too high");
    }

    function _calculateFee(uint256 gasCost, uint256 price) internal view returns (uint256 fee) {
        // Calculate fee with markup in a single division to avoid precision loss
        // Formula: baseFee * (10000 + feeMarkupBps) / 10000
        // Where baseFee = gasCost * price / 1e18
        // Combined: gasCost * price * (10000 + feeMarkupBps) / (1e18 * 10000)
        fee = (gasCost * price * (10_000 + feeMarkupBps)) / (1e18 * 10_000);
        if (fee < minFee) fee = minFee;
    }

    function _verifyUserFunds(address user, uint256 requiredFee) internal view {
        require(IERC20(feeToken).allowance(user, address(this)) >= requiredFee, "GasX: Insufficient allowance");
        require(IERC20(feeToken).balanceOf(user) >= requiredFee, "GasX: Insufficient balance");
    }

    // --- Post-Op Payment ---

    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256) internal override {
        if (mode != PostOpMode.opSucceeded) return;

        // Decode the price, sender address, and userOpHash from the context
        (uint256 onChainPrice, address sender, bytes32 userOpHash) = abi.decode(context, (uint256, address, bytes32));

        // Recalculate the fee with the actual gas cost using single division to avoid precision loss
        // Formula: actualGasCost * onChainPrice * (10000 + feeMarkupBps) / (1e18 * 10000)
        uint256 actualFee = (actualGasCost * onChainPrice * (10_000 + feeMarkupBps)) / (1e18 * 10_000);

        // Apply minimum fee
        if (actualFee < minFee) {
            actualFee = minFee;
        }

        // Collect the fee using SafeERC20
        IERC20(feeToken).safeTransferFrom(sender, address(this), actualFee);

        // Update tracking
        totalFeesCollected += actualFee;

        emit FeeCharged(userOpHash, sender, actualFee);
    }

    // --- Admin Functions ---

    /**
     * @notice Update the oracle signer address
     * @param _newSigner New signer address
     */
    function setOracleSigner(address _newSigner) external onlyOwner {
        require(_newSigner != address(0), "GasX: Invalid signer address");
        address previousSigner = oracleSigner;
        oracleSigner = _newSigner;
        emit OracleSignerUpdated(previousSigner, _newSigner);
    }

    /**
     * @notice Update the minimum fee
     * @param _newMinFee New minimum fee in fee token units
     */
    function setMinFee(uint256 _newMinFee) external onlyOwner {
        uint256 previousMinFee = minFee;
        minFee = _newMinFee;
        emit MinFeeUpdated(previousMinFee, _newMinFee);
    }

    /**
     * @notice Update the fee markup
     * @param _newMarkupBps New markup in basis points (max 1000 = 10%)
     */
    function setFeeMarkup(uint256 _newMarkupBps) external onlyOwner {
        require(_newMarkupBps <= 1000, "GasX: Markup too high");
        uint256 previousMarkupBps = feeMarkupBps;
        feeMarkupBps = _newMarkupBps;
        emit FeeMarkupUpdated(previousMarkupBps, _newMarkupBps);
    }

    /**
     * @notice Withdraw accumulated ERC20 fees to a specified address
     * @param _to Recipient address
     * @param _amount Amount to withdraw (0 = all)
     */
    function withdrawFees(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "GasX: Invalid recipient");
        uint256 balance = IERC20(feeToken).balanceOf(address(this));
        uint256 withdrawAmount = _amount == 0 ? balance : _amount;
        require(withdrawAmount <= balance, "GasX: Insufficient balance");

        IERC20(feeToken).safeTransfer(_to, withdrawAmount);
        emit FeesWithdrawn(_to, withdrawAmount);
    }

    /**
     * @notice Withdraw any ERC20 token (for recovering stuck tokens)
     * @dev Cannot withdraw the fee token - use withdrawFees() instead
     * @param _token Token address
     * @param _to Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawToken(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "GasX: Invalid recipient");
        require(_token != feeToken, "GasX: Use withdrawFees for fee token");
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokenRecovered(_token, _to, _amount);
    }

    /**
     * @notice Pause the paymaster (emergency stop)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the paymaster
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of Ether accidentally sent to this contract
     * @dev This only withdraws ETH held directly by the contract, NOT the deposit
     * with the EntryPoint (use withdrawTo from BasePaymaster for that).
     * @param _to The address to send the recovered Ether to
     * @param _amount The amount of Ether to withdraw (0 = withdraw all)
     */
    function emergencyWithdrawEth(address payable _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "GasX: Invalid recipient");
        uint256 toWithdraw = _amount == 0 ? address(this).balance : _amount;
        require(toWithdraw <= address(this).balance, "GasX: Insufficient balance");
        // CEI pattern: emit event before external call to prevent reentrancy issues
        emit EmergencyWithdraw(_to, toWithdraw);
        (bool success, ) = _to.call{ value: toWithdraw }("");
        require(success, "GasX: ETH transfer failed");
    }

    // --- Receive Function ---

    /**
     * @notice Allows the contract to receive ETH directly
     * @dev ETH received this way can be recovered via emergencyWithdrawEth().
     * Normal paymaster funding should use deposit() or addStake() to fund via EntryPoint.
     */
    receive() external payable {}

    // --- View Functions ---

    /**
     * @notice Get the current fee token balance held by this contract
     */
    function getFeeBalance() external view returns (uint256) {
        return IERC20(feeToken).balanceOf(address(this));
    }

    /**
     * @notice Estimate the fee for a given gas cost
     * @param _gasCost Estimated gas cost in wei
     * @return estimatedFee The estimated fee in fee token units
     */
    function estimateFee(uint256 _gasCost) external view returns (uint256 estimatedFee) {
        return _estimateFee(_gasCost);
    }

    /**
     * @notice Internal fee estimation function
     * @param _gasCost Estimated gas cost in wei
     * @return estimatedFee The estimated fee in fee token units
     */
    function _estimateFee(uint256 _gasCost) internal view returns (uint256 estimatedFee) {
        uint256 onChainPrice = priceOracle.computeQuoteAverage(1e18, priceQuoteBaseToken, feeToken);
        // Calculate fee with markup in single division to avoid precision loss
        // Formula: _gasCost * onChainPrice * (10000 + feeMarkupBps) / (1e18 * 10000)
        estimatedFee = (_gasCost * onChainPrice * (10_000 + feeMarkupBps)) / (1e18 * 10_000);
        if (estimatedFee < minFee) {
            estimatedFee = minFee;
        }
    }

    /**
     * @notice Check if an address has sufficient allowance and balance
     * @param _user User address
     * @param _estimatedGasCost Estimated gas cost
     * @return hasAllowance Whether user has approved enough
     * @return hasBalance Whether user has enough balance
     * @return requiredAmount The required fee amount
     */
    function checkUserReady(
        address _user,
        uint256 _estimatedGasCost
    ) external view returns (bool hasAllowance, bool hasBalance, uint256 requiredAmount) {
        requiredAmount = _estimateFee(_estimatedGasCost);
        hasAllowance = IERC20(feeToken).allowance(_user, address(this)) >= requiredAmount;
        hasBalance = IERC20(feeToken).balanceOf(_user) >= requiredAmount;
    }

    // --- Helper Functions ---

    function _decodePaymasterData(
        bytes calldata pData
    ) private pure returns (uint256 price, uint48 expiry, bytes memory signature) {
        // Skip the static PAYMASTER_DATA_OFFSET bytes (address + gas limits)
        bytes calldata data = pData[PAYMASTER_DATA_OFFSET:];
        require(data.length >= PRICE_SIZE + EXPIRY_SIZE, "GasX: Invalid paymaster data length");

        price = abi.decode(data[:PRICE_SIZE], (uint256));
        expiry = uint48(bytes6(data[PRICE_SIZE:PRICE_SIZE + EXPIRY_SIZE]));
        signature = data[PRICE_SIZE + EXPIRY_SIZE:];
    }
}
