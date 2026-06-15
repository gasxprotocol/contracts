// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { GasXPaymasterBase } from "./GasXPaymasterBase.sol";
import { GasXPolicyLib } from "../libraries/GasXPolicyLib.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";

/// @notice Minimal price-oracle surface used only as a postOp deviation backstop (cross-read allowed there).
interface IGasXPriceOracle {
    function computeQuoteAverage(uint256 amount, address base, address quote) external view returns (uint256);
}

/**
 * @title  GasXERC20FeePaymaster
 * @author GasX
 * @notice Sponsors gas in ETH and charges the user an equivalent ERC20 fee — built on `GasXPaymasterBase`.
 *         Validation verifies ONLY the signed approval (the signer commits the token price in the approval's
 *         `eligibilityRef`), so validation reads NO oracle and moves NO tokens (ERC-7562-safe, identical
 *         posture to the whitelist strategy). The token fee is charged ONCE in postOp at the actual gas cost,
 *         clamped by the on-chain oracle (deviation backstop), best-effort (a charge failure cannot revert the
 *         op — bounded one-op loss), with balance-delta accounting (fee-on-transfer safe), CEI + nonReentrant.
 * @dev    strategyId = keccak256("gasx.erc20"). The off-chain signer is responsible for only signing approvals
 *         for users it has verified hold sufficient feeToken balance+allowance (solvency = the eligibility gate).
 *         Not upgradeable (a deposit-holding proxy is a drain surface).
 */
contract GasXERC20FeePaymaster is GasXPaymasterBase, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The ERC20 charged as the fee (e.g. USDC). MUST be a standard, non-rebasing ERC20.
    address public immutable feeToken;
    /// @notice feeToken decimals (asserted against the token at deploy; informational for off-chain math).
    uint8 public immutable feeTokenDecimals;
    /// @notice The base token for oracle quotes (e.g. WETH).
    address public immutable priceQuoteBaseToken;
    /// @notice On-chain oracle used ONLY in postOp as a deviation cap on the signer-committed price.
    IGasXPriceOracle public immutable priceOracle;

    /// @notice Max accepted deviation of the signed price above the oracle price (postOp clamp).
    uint256 public constant PRICE_DEVIATION_BPS = 500; // 5%
    uint256 public totalFeesCollected;

    event FeeCharged(bytes32 indexed userOpHash, address indexed user, uint256 feeAmount);
    event FeeChargeFailed(bytes32 indexed userOpHash, address indexed user, uint256 feeAmount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    constructor(
        IEntryPoint _entryPoint,
        address _policyManager,
        string memory name,
        string memory version,
        address _feeToken,
        address _priceOracle,
        address _priceQuoteBaseToken
    ) GasXPaymasterBase(_entryPoint, _policyManager, name, version) {
        require(
            _feeToken != address(0) && _priceOracle != address(0) && _priceQuoteBaseToken != address(0),
            "GasX: zero addr"
        );
        feeToken = _feeToken;
        feeTokenDecimals = IERC20Metadata(_feeToken).decimals(); // asserts the token exposes decimals()
        priceOracle = IGasXPriceOracle(_priceOracle);
        priceQuoteBaseToken = _priceQuoteBaseToken;
    }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("gasx.erc20");
    }

    function supportsCampaign(bytes32) external pure override returns (bool) {
        return true;
    }

    /// @dev `price` = feeToken smallest-units per 1e18 wei of ETH gas (the signer bakes decimals + markup in).
    function _feeFor(uint256 gasWei, uint256 price) internal pure returns (uint256) {
        return (gasWei * price) / 1e18;
    }

    // --- validation (ERC-7562-safe: signed approval only — NO oracle read, NO token move) ---
    function _validatePaymasterUserOp(PackedUserOperation calldata op, bytes32, uint256 maxCost)
        internal
        override
        whenNotPaused
        returns (bytes memory context, uint256 validationData)
    {
        GasXPolicyLib.SignedApproval memory a;
        (a, validationData) = _verifyApproval(op, maxCost);
        // signer-committed token price; validation does NOT read the oracle (resolved Open Q / audit gasx-fwd-8)
        uint256 price = uint256(a.eligibilityRef);
        context = abi.encode(a.campaignId, a.sender, a.userOpHash, price);
        return (context, validationData);
    }

    // --- postOp (charge once at actual cost; never reverts upward) ---
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        internal
        override
        nonReentrant
    {
        if (mode == PostOpMode.postOpReverted) return;
        (bytes32 campaignId, address sender, bytes32 userOpHash, uint256 price) =
            abi.decode(context, (bytes32, address, bytes32, uint256));

        // ETH budget: non-reverting decrement (try/catch absorbs an unexpected PolicyManager revert).
        try IGasXPolicyManager(policyManagerAddr).consumeUpTo(campaignId, actualGasCost) returns (uint256 c) {
            emit GasXSponsored(campaignId, sender, userOpHash, c);
        } catch {
            emit ConsumeFailed(campaignId, actualGasCost);
        }

        // Token fee at the ACTUAL gas cost, clamped by the oracle deviation backstop.
        uint256 fee = _feeFor(actualGasCost, price);
        uint256 cap = _oracleCap(actualGasCost);
        if (cap != 0 && fee > cap) fee = cap;
        if (fee == 0) return;

        // Best-effort charge: a failure (no allowance/balance) must NOT revert the op — the gas is already
        // spent; emit and move on (bounded one-op loss, by the off-chain eligibility-gate design). CEI:
        // effects (totalFeesCollected) recorded from the measured balance delta (fee-on-transfer safe).
        uint256 beforeBal = IERC20(feeToken).balanceOf(address(this));
        try IERC20(feeToken).transferFrom(sender, address(this), fee) returns (bool ok) {
            if (ok) {
                uint256 received = IERC20(feeToken).balanceOf(address(this)) - beforeBal;
                totalFeesCollected += received;
                emit FeeCharged(userOpHash, sender, received);
            } else {
                emit FeeChargeFailed(userOpHash, sender, fee);
            }
        } catch {
            emit FeeChargeFailed(userOpHash, sender, fee);
        }
    }

    /// @dev postOp-only oracle deviation cap (cross-read allowed here). Returns 0 (no clamp) if the oracle is
    ///      unavailable, so a transient oracle failure cannot revert postOp; the trusted signer is the primary
    ///      price authority and the oracle is the backstop.
    function _oracleCap(uint256 gasWei) internal view returns (uint256) {
        try priceOracle.computeQuoteAverage(1e18, priceQuoteBaseToken, feeToken) returns (uint256 oraclePrice) {
            if (oraclePrice == 0) return 0;
            uint256 maxPrice = (oraclePrice * (10_000 + PRICE_DEVIATION_BPS)) / 10_000;
            return _feeFor(gasWei, maxPrice);
        } catch {
            return 0;
        }
    }

    // --- admin ---
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "GasX: Invalid recipient");
        uint256 bal = IERC20(feeToken).balanceOf(address(this));
        uint256 amt = amount == 0 ? bal : amount;
        require(amt <= bal, "GasX: Insufficient balance");
        IERC20(feeToken).safeTransfer(to, amt);
        emit FeesWithdrawn(to, amt);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "GasX: Invalid recipient");
        require(token != feeToken, "GasX: Use withdrawFees");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawEth(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "GasX: Invalid recipient");
        uint256 toWithdraw = amount == 0 ? address(this).balance : amount;
        require(toWithdraw <= address(this).balance, "GasX: Insufficient balance");
        emit EmergencyWithdraw(to, toWithdraw);
        (bool ok,) = to.call{ value: toWithdraw }("");
        require(ok, "GasX: ETH transfer failed");
    }

    function getFeeBalance() external view returns (uint256) {
        return IERC20(feeToken).balanceOf(address(this));
    }

    receive() external payable { }
}
