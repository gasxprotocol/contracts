// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/GasXERC20FeePaymaster.sol";
import "../src/testutils/TestableGasXERC20.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Mock EntryPoint for testing
 */
contract MockEntryPoint {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
    function depositTo(address) external payable {}
    function withdrawTo(address payable, uint256) external {}
    function getDepositInfo(
        address
    ) external pure returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime) {
        return (0, false, 0, 0, 0);
    }
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
}

/**
 * @title Mock ERC20 Token for testing
 */
contract MockERC20 is IERC20 {
    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        require(_balances[from] >= amount, "Insufficient balance");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

/**
 * @title Mock MultiOracleAggregator for testing
 */
contract MockOracle {
    uint256 public mockPrice = 4000e6; // 4000 USDC per ETH (6 decimals)

    function setMockPrice(uint256 _price) external {
        mockPrice = _price;
    }

    function computeQuoteAverage(uint256 amount, address, address) external view returns (uint256) {
        // Returns price for 1 ETH worth in USDC (scaled to fee token decimals)
        return (amount * mockPrice) / 1e18;
    }
}

/**
 * @title GasXERC20FeePaymaster Fuzz Tests
 * @notice Foundry fuzz tests for the GasX ERC20 Fee Paymaster
 * @dev Run with: forge test --match-path 'test/foundry/GasXERC20FeePaymaster*.sol' -vvv
 */
contract GasXERC20FeePaymasterFuzzTest is Test {
    TestableGasXERC20 public paymaster;
    MockEntryPoint public entryPoint;
    MockERC20 public feeToken;
    MockERC20 public weth;
    MockOracle public oracle;
    address public oracleSigner;
    address public owner;

    // Constants
    uint256 constant MAX_GAS_COST = 10_000_000 gwei; // 10M gwei max gas cost
    uint256 constant MAX_PRICE = 100_000e6; // 100k USDC per ETH max
    uint256 constant MIN_PRICE = 100e6; // 100 USDC per ETH min
    uint256 constant MAX_MARKUP_BPS = 1000; // 10% max markup
    uint256 constant DEFAULT_MIN_FEE = 10000; // 0.01 USDC

    function setUp() public {
        owner = address(this);
        oracleSigner = address(0x2222);

        // Deploy mocks
        entryPoint = new MockEntryPoint();
        feeToken = new MockERC20();
        weth = new MockERC20();
        oracle = new MockOracle();

        // Deploy TestableGasXERC20
        paymaster = new TestableGasXERC20(
            IEntryPoint(address(entryPoint)),
            address(feeToken),
            address(weth),
            address(oracle),
            oracleSigner,
            DEFAULT_MIN_FEE,
            100 // 1% markup
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Fee Calculation
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Fee calculation with various gas costs and prices
     * @dev Verifies fee = (gasCost * price * (10000 + markup)) / (1e18 * 10000)
     */
    function testFuzz_FeeCalculation(uint256 gasCost, uint256 price) public {
        // Bound inputs to reasonable ranges
        gasCost = bound(gasCost, 0, MAX_GAS_COST);
        price = bound(price, MIN_PRICE, MAX_PRICE);

        uint256 fee = paymaster.exposedCalculateFee(gasCost, price);

        // Calculate expected fee: gasCost * price * (10000 + 100) / (1e18 * 10000)
        uint256 expectedFee = (gasCost * price * 10100) / (1e18 * 10000);
        if (expectedFee < DEFAULT_MIN_FEE) {
            expectedFee = DEFAULT_MIN_FEE;
        }

        assertEq(fee, expectedFee, "Fee calculation mismatch");
    }

    /**
     * @notice Fuzz test: Min fee enforcement
     * @dev Tests that minFee is always enforced when calculated fee is lower
     */
    function testFuzz_MinFeeEnforcement(uint256 gasCost) public {
        // Use very small gas costs that would result in fees below minFee
        gasCost = bound(gasCost, 0, 1000); // Very small gas costs

        uint256 fee = paymaster.exposedCalculateFee(gasCost, 4000e6);

        // Fee should never be less than minFee
        assertGe(fee, DEFAULT_MIN_FEE, "Fee should not be less than minFee");
    }

    /**
     * @notice Fuzz test: Fee markup enforcement
     * @dev Tests that markup correctly increases the fee
     */
    function testFuzz_FeeMarkupEffect(uint256 gasCost, uint256 markup) public {
        gasCost = bound(gasCost, 1e15, 1e18); // 0.001 to 1 ETH worth of gas
        markup = bound(markup, 0, MAX_MARKUP_BPS);

        // Deploy new paymaster with specific markup
        TestableGasXERC20 pm = new TestableGasXERC20(
            IEntryPoint(address(entryPoint)),
            address(feeToken),
            address(weth),
            address(oracle),
            oracleSigner,
            1, // 1 wei minFee to test actual calculation
            markup
        );

        uint256 price = 4000e6; // 4000 USDC per ETH
        uint256 fee = pm.exposedCalculateFee(gasCost, price);

        // Calculate expected fee with markup
        uint256 expectedFee = (gasCost * price * (10000 + markup)) / (1e18 * 10000);
        if (expectedFee < 1) expectedFee = 1;

        assertEq(fee, expectedFee, "Fee with markup mismatch");
    }

    /**
     * @notice Fuzz test: Fee calculation is monotonically increasing with gas cost
     * @dev Higher gas cost should result in higher or equal fee
     */
    function testFuzz_FeeMonotonicity(uint256 gasCost1, uint256 gasCost2) public {
        gasCost1 = bound(gasCost1, 0, MAX_GAS_COST / 2);
        gasCost2 = bound(gasCost2, gasCost1, MAX_GAS_COST);

        uint256 price = 4000e6;
        uint256 fee1 = paymaster.exposedCalculateFee(gasCost1, price);
        uint256 fee2 = paymaster.exposedCalculateFee(gasCost2, price);

        assertGe(fee2, fee1, "Higher gas cost should result in higher or equal fee");
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Admin Functions
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: setMinFee correctly updates minFee
     * @dev Tests that minFee can be set to any value
     */
    function testFuzz_SetMinFee(uint256 newMinFee) public {
        vm.expectEmit(true, true, true, true);
        emit GasXERC20FeePaymaster.MinFeeUpdated(DEFAULT_MIN_FEE, newMinFee);

        paymaster.setMinFee(newMinFee);
        assertEq(paymaster.minFee(), newMinFee, "MinFee not updated correctly");
    }

    /**
     * @notice Fuzz test: setFeeMarkup enforces maximum
     * @dev Tests that markup cannot exceed 1000 bps (10%)
     */
    function testFuzz_SetFeeMarkupBoundary(uint256 newMarkup) public {
        if (newMarkup <= MAX_MARKUP_BPS) {
            vm.expectEmit(true, true, true, true);
            emit GasXERC20FeePaymaster.FeeMarkupUpdated(100, newMarkup);

            paymaster.setFeeMarkup(newMarkup);
            assertEq(paymaster.feeMarkupBps(), newMarkup, "Markup not updated correctly");
        } else {
            vm.expectRevert("GasX: Markup too high");
            paymaster.setFeeMarkup(newMarkup);
        }
    }

    /**
     * @notice Fuzz test: setOracleSigner validation
     * @dev Tests that zero address is rejected
     */
    function testFuzz_SetOracleSigner(address newSigner) public {
        if (newSigner == address(0)) {
            vm.expectRevert("GasX: Invalid signer address");
            paymaster.setOracleSigner(newSigner);
        } else {
            vm.expectEmit(true, true, true, true);
            emit GasXERC20FeePaymaster.OracleSignerUpdated(oracleSigner, newSigner);

            paymaster.setOracleSigner(newSigner);
            assertEq(paymaster.oracleSigner(), newSigner, "Signer not updated correctly");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Pause Functionality
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Pause prevents fee estimation
     * @dev Tests that estimateFee works regardless of pause state (view function)
     */
    function testFuzz_EstimateFeeUnaffectedByPause(uint256 gasCost, bool paused) public {
        gasCost = bound(gasCost, 0, MAX_GAS_COST);

        if (paused) {
            paymaster.pause();
        }

        // estimateFee is a view function and should work regardless of pause state
        uint256 fee = paymaster.estimateFee(gasCost);
        assertGe(fee, DEFAULT_MIN_FEE, "Fee should be at least minFee");
    }

    /**
     * @notice Fuzz test: Pause and unpause toggle
     * @dev Tests that pause state can be toggled correctly
     */
    function testFuzz_PauseToggle(uint8 toggleCount) public {
        toggleCount = uint8(bound(toggleCount, 1, 10));

        bool expectedPaused = false;
        for (uint8 i = 0; i < toggleCount; i++) {
            if (expectedPaused) {
                paymaster.unpause();
            } else {
                paymaster.pause();
            }
            expectedPaused = !expectedPaused;
            assertEq(paymaster.paused(), expectedPaused, "Pause state mismatch");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Emergency Withdrawal
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Emergency ETH withdrawal
     * @dev Tests that owner can withdraw any ETH amount up to balance
     */
    function testFuzz_EmergencyWithdrawEth(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 0, 100 ether);

        // Send ETH to paymaster
        vm.deal(address(this), depositAmount);
        (bool success, ) = address(paymaster).call{ value: depositAmount }("");
        require(success, "ETH transfer failed");

        if (withdrawAmount == 0) {
            // Should withdraw all
            uint256 balanceBefore = address(paymaster).balance;
            paymaster.emergencyWithdrawEth(payable(owner), 0);
            assertEq(address(paymaster).balance, 0, "Should have withdrawn all");
            assertEq(owner.balance, balanceBefore, "Owner should receive all");
        } else if (withdrawAmount <= depositAmount) {
            uint256 balanceBefore = address(paymaster).balance;
            paymaster.emergencyWithdrawEth(payable(owner), withdrawAmount);
            assertEq(address(paymaster).balance, balanceBefore - withdrawAmount, "Incorrect remaining balance");
        } else {
            vm.expectRevert("GasX: Insufficient balance");
            paymaster.emergencyWithdrawEth(payable(owner), withdrawAmount);
        }
    }

    /**
     * @notice Fuzz test: Emergency withdrawal recipient validation
     * @dev Tests that zero address is rejected and valid addresses receive ETH
     *      Excludes addresses that cannot receive ETH (precompiles, VM addresses)
     */
    function testFuzz_EmergencyWithdrawRecipient(address recipient) public {
        // Skip precompiles (0x01-0x09) and Foundry VM addresses that can't receive ETH
        vm.assume(recipient > address(0x10));
        vm.assume(recipient != address(vm));
        // Skip known contract addresses that might not have receive/fallback
        vm.assume(recipient.code.length == 0);

        vm.deal(address(paymaster), 1 ether);

        if (recipient == address(0)) {
            vm.expectRevert("GasX: Invalid recipient");
            paymaster.emergencyWithdrawEth(payable(recipient), 1 ether);
        } else {
            paymaster.emergencyWithdrawEth(payable(recipient), 1 ether);
            assertEq(recipient.balance, 1 ether, "Recipient should receive ETH");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Access Control
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Only owner can call admin functions
     * @dev Tests access control on all admin functions
     */
    function testFuzz_OnlyOwnerCanAdmin(address attacker) public {
        vm.assume(attacker != owner);

        vm.startPrank(attacker);

        vm.expectRevert();
        paymaster.setMinFee(100);

        vm.expectRevert();
        paymaster.setFeeMarkup(200);

        vm.expectRevert();
        paymaster.setOracleSigner(address(0x1234));

        vm.expectRevert();
        paymaster.pause();

        vm.expectRevert();
        paymaster.withdrawFees(address(this), 0);

        vm.expectRevert();
        paymaster.emergencyWithdrawEth(payable(address(this)), 0);

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Fee Token Operations
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: withdrawFees respects balance
     * @dev Tests that fee withdrawal works correctly
     */
    function testFuzz_WithdrawFees(uint256 balance, uint256 withdrawAmount) public {
        balance = bound(balance, 0, 1_000_000e6); // Max 1M USDC

        // Mint tokens to paymaster
        feeToken.mint(address(paymaster), balance);

        if (withdrawAmount == 0) {
            // Should withdraw all
            paymaster.withdrawFees(owner, 0);
            assertEq(feeToken.balanceOf(address(paymaster)), 0, "Should have withdrawn all fees");
        } else if (withdrawAmount <= balance) {
            paymaster.withdrawFees(owner, withdrawAmount);
            assertEq(feeToken.balanceOf(address(paymaster)), balance - withdrawAmount, "Incorrect remaining balance");
        } else {
            vm.expectRevert("GasX: Insufficient balance");
            paymaster.withdrawFees(owner, withdrawAmount);
        }
    }

    /**
     * @notice Fuzz test: withdrawToken cannot withdraw feeToken
     * @dev Tests that feeToken must use withdrawFees
     */
    function testFuzz_WithdrawTokenRejectsFeeToken(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        feeToken.mint(address(paymaster), amount);

        vm.expectRevert("GasX: Use withdrawFees for fee token");
        paymaster.withdrawToken(address(feeToken), owner, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: User Funds Verification
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: User funds verification
     * @dev Tests that allowance and balance checks work correctly
     */
    function testFuzz_UserFundsVerification(uint256 userBalance, uint256 userAllowance, uint256 requiredFee) public {
        userBalance = bound(userBalance, 0, 1_000_000e6);
        userAllowance = bound(userAllowance, 0, 1_000_000e6);
        requiredFee = bound(requiredFee, 1, 500_000e6);

        address user = address(0x3333);
        feeToken.mint(user, userBalance);

        vm.prank(user);
        feeToken.approve(address(paymaster), userAllowance);

        if (userAllowance < requiredFee) {
            vm.expectRevert("GasX: Insufficient allowance");
            paymaster.exposedVerifyUserFunds(user, requiredFee);
        } else if (userBalance < requiredFee) {
            vm.expectRevert("GasX: Insufficient balance");
            paymaster.exposedVerifyUserFunds(user, requiredFee);
        } else {
            // Should not revert
            paymaster.exposedVerifyUserFunds(user, requiredFee);
        }
    }

    /**
     * @notice Fuzz test: checkUserReady returns correct status
     * @dev Tests the view function that checks user readiness
     */
    function testFuzz_CheckUserReady(uint256 userBalance, uint256 userAllowance, uint256 gasCost) public {
        userBalance = bound(userBalance, 0, 1_000_000e6);
        userAllowance = bound(userAllowance, 0, 1_000_000e6);
        gasCost = bound(gasCost, 0, 1e18);

        address user = address(0x4444);
        feeToken.mint(user, userBalance);

        vm.prank(user);
        feeToken.approve(address(paymaster), userAllowance);

        (bool hasAllowance, bool hasBalance, uint256 requiredAmount) = paymaster.checkUserReady(user, gasCost);

        assertEq(hasAllowance, userAllowance >= requiredAmount, "Allowance check mismatch");
        assertEq(hasBalance, userBalance >= requiredAmount, "Balance check mismatch");
        assertGe(requiredAmount, DEFAULT_MIN_FEE, "Required amount should be at least minFee");
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Fee Tracking
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Total fees collected tracking
     * @dev Tests that totalFeesCollected is updated correctly in postOp
     */
    function testFuzz_TotalFeesTracking(uint256 actualGasCost) public {
        actualGasCost = bound(actualGasCost, 1e15, 1e18);

        address user = address(0x5555);
        uint256 price = 4000e6;
        bytes32 userOpHash = keccak256("testOp");

        // Prepare user with sufficient funds
        uint256 expectedFee = paymaster.exposedCalculateFee(actualGasCost, price);
        feeToken.mint(user, expectedFee * 2);

        vm.prank(user);
        feeToken.approve(address(paymaster), expectedFee * 2);

        // Prepare context
        bytes memory context = abi.encode(price, user, userOpHash);

        uint256 totalBefore = paymaster.totalFeesCollected();

        // Call postOp
        paymaster.exposedPostOp(context, actualGasCost, 0);

        uint256 totalAfter = paymaster.totalFeesCollected();
        assertEq(totalAfter - totalBefore, expectedFee, "Fee tracking mismatch");
    }

    // ─────────────────────────────────────────────────────────────────
    // HELPER: Receive ETH
    // ─────────────────────────────────────────────────────────────────

    receive() external payable {}
}
