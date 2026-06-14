// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/GasXWhitelistPaymaster.sol";
import "../src/core/GasXConfig.sol";
import "../src/testutils/TestableGasX.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";

/**
 * @title Mock EntryPoint for testing
 */
contract MockEntryPoint {
    // Required by BasePaymaster constructor
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
 * @title GasXWhitelistPaymaster Fuzz Tests
 * @notice Foundry fuzz tests for the GasX Whitelist Paymaster
 * @dev Run with: forge test --match-path 'test/foundry/GasXWhitelistPaymaster*.sol' -vvv
 */
contract GasXWhitelistPaymasterFuzzTest is Test {
    TestableGasX public paymaster;
    GasXConfig public config;
    MockEntryPoint public entryPoint;
    address public treasury;
    address public oracleSigner;
    address public owner;

    // Constants
    uint256 constant MAX_GAS_LIMIT = 30_000_000; // Block gas limit
    uint256 constant MAX_USD_LIMIT = 1_000_000e6; // 1M USD with 6 decimals

    function setUp() public {
        owner = address(this);
        treasury = address(0x1111);
        oracleSigner = address(0x2222);

        // Deploy mock EntryPoint
        entryPoint = new MockEntryPoint();

        // Deploy GasXConfig
        config = new GasXConfig(oracleSigner);

        // Deploy TestableGasX (inherits from GasXWhitelistPaymaster)
        paymaster = new TestableGasX(address(entryPoint), address(config), treasury);

        // Enable dev mode for testing
        paymaster.setDevMode(true);
    }

    // ─────────────────────────────────────────────────────────────────
    // FUZZ TESTS: Gas Limit Enforcement
    // ─────────────────────────────────────────────────────────────────

    /**
     * @notice Fuzz test: Gas limit boundary enforcement
     * @dev Tests that gas limits are correctly enforced at boundaries
     */
    function testFuzz_GasLimitBoundary(uint256 setLimit, uint256 opGasLimit) public {
        // Bound inputs to reasonable ranges
        setLimit = bound(setLimit, 1, MAX_GAS_LIMIT);
        opGasLimit = bound(opGasLimit, 1, MAX_GAS_LIMIT);

        // Set up paymaster
        paymaster.setLimit(setLimit, 0);
        bytes4 selector = bytes4(keccak256("testFunction()"));
        paymaster.setSelector(selector, true);

        // Create UserOp with the specified gas limit
        PackedUserOperation memory op = _createBaseUserOp(selector, opGasLimit);

        if (opGasLimit <= setLimit) {
            // Should succeed
            (bytes memory ctx, uint256 vd) = paymaster.exposedValidate(op, bytes32(0), 0);
            assertEq(ctx.length, 0, "Context should be empty");
            assertEq(vd, 0, "ValidationData should be 0");
        } else {
            // Should revert
            vm.expectRevert("GasX: Gas limit exceeded");
            paymaster.exposedValidate(op, bytes32(0), 0);
        }
    }

    /**
     * @notice Fuzz test: Selector whitelist enforcement
     * @dev Tests that only whitelisted selectors are accepted
     */
    function testFuzz_SelectorWhitelist(bytes4 selector, bool isWhitelisted) public {
        paymaster.setLimit(1_000_000, 0);

        // Set selector whitelist status
        paymaster.setSelector(selector, isWhitelisted);

        // Verify the selector status
        assertEq(paymaster.allowedSelectors(selector), isWhitelisted);

        // Create UserOp
        PackedUserOperation memory op = _createBaseUserOp(selector, 100_000);

        if (isWhitelisted) {
            // Should succeed
            (bytes memory ctx, uint256 vd) = paymaster.exposedValidate(op, bytes32(0), 0);
            assertEq(ctx.length, 0, "Context should be empty");
            assertEq(vd, 0, "ValidationData should be 0");
        } else {
            // Should revert
            vm.expectRevert("GasX: Disallowed function");
            paymaster.exposedValidate(op, bytes32(0), 0);
        }
    }

    /**
     * @notice Fuzz test: Multiple selector toggling
     * @dev Tests that selectors can be added and removed correctly
     */
    function testFuzz_SelectorToggle(bytes4 selector, uint8 toggleCount) public {
        toggleCount = uint8(bound(toggleCount, 1, 10));

        bool expectedState = false;
        for (uint8 i = 0; i < toggleCount; i++) {
            expectedState = !expectedState;
            paymaster.setSelector(selector, expectedState);
            assertEq(paymaster.allowedSelectors(selector), expectedState);
        }
    }

    /**
     * @notice Fuzz test: Limits can be set to any valid value
     * @dev Tests that limits struct is correctly updated
     */
    function testFuzz_SetLimits(uint256 maxGas, uint256 maxUsd) public {
        maxGas = bound(maxGas, 0, MAX_GAS_LIMIT);
        maxUsd = bound(maxUsd, 0, MAX_USD_LIMIT);

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit GasXWhitelistPaymaster.LimitsUpdated(maxGas, maxUsd);

        paymaster.setLimit(maxGas, maxUsd);

        (uint256 storedGas, uint256 storedUsd) = paymaster.limits();
        assertEq(storedGas, maxGas, "maxGas should match");
        assertEq(storedUsd, maxUsd, "maxUsd should match");
    }

    /**
     * @notice Fuzz test: Dev mode toggle
     * @dev Tests that dev mode can be toggled correctly
     */
    function testFuzz_DevModeToggle(bool enabled) public {
        vm.expectEmit(true, true, true, true);
        emit GasXWhitelistPaymaster.DevModeChanged(enabled);

        paymaster.setDevMode(enabled);
        assertEq(paymaster.isDev(), enabled, "Dev mode should match");
    }

    /**
     * @notice Fuzz test: Pause prevents validation
     * @dev Tests that validation fails when paused
     */
    function testFuzz_PauseBlocksValidation(bytes4 selector, uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 1, 1_000_000);

        paymaster.setLimit(gasLimit, 0);
        paymaster.setSelector(selector, true);
        paymaster.pause();

        PackedUserOperation memory op = _createBaseUserOp(selector, gasLimit);

        // whenNotPaused modifier uses OpenZeppelin's EnforcedPause() custom error
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        paymaster.exposedValidate(op, bytes32(0), 0);
    }

    /**
     * @notice Fuzz test: Unpause allows validation again
     * @dev Tests that validation works after unpausing
     */
    function testFuzz_UnpauseAllowsValidation(bytes4 selector, uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 1, 1_000_000);

        paymaster.setLimit(gasLimit, 0);
        paymaster.setSelector(selector, true);

        // Pause and unpause
        paymaster.pause();
        paymaster.unpause();

        PackedUserOperation memory op = _createBaseUserOp(selector, gasLimit);

        // Should succeed after unpause
        (bytes memory ctx, uint256 vd) = paymaster.exposedValidate(op, bytes32(0), 0);
        assertEq(ctx.length, 0, "Context should be empty");
        assertEq(vd, 0, "ValidationData should be 0");
    }

    /**
     * @notice Fuzz test: PostOp event emission with various gas values
     * @dev Tests that GasSponsored event is emitted correctly
     */
    function testFuzz_PostOpEvent(uint256 gasCost, uint256 feePerGas) public {
        gasCost = bound(gasCost, 0, 10_000_000);
        feePerGas = bound(feePerGas, 0, 1000 gwei);

        uint256 expectedFee = gasCost * feePerGas;

        vm.expectEmit(true, true, true, true);
        emit GasXWhitelistPaymaster.GasSponsored(address(this), gasCost, expectedFee);

        paymaster.exposedPostOp("", gasCost, feePerGas);
    }

    /**
     * @notice Fuzz test: Only owner can call admin functions
     * @dev Tests access control on admin functions
     */
    function testFuzz_OnlyOwnerCanAdmin(address attacker) public {
        vm.assume(attacker != owner);

        vm.startPrank(attacker);

        vm.expectRevert();
        paymaster.setLimit(100, 0);

        vm.expectRevert();
        paymaster.setSelector(bytes4(0x12345678), true);

        vm.expectRevert();
        paymaster.setDevMode(true);

        vm.expectRevert();
        paymaster.pause();

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────
    // HELPER FUNCTIONS
    // ─────────────────────────────────────────────────────────────────

    function _createBaseUserOp(
        bytes4 selector,
        uint256 callGasLimit
    ) internal pure returns (PackedUserOperation memory) {
        // Pack accountGasLimits: [verificationGasLimit(16B) | callGasLimit(16B)]
        bytes32 accountGasLimits = bytes32((uint256(0) << 128) | uint256(callGasLimit));

        return
            PackedUserOperation({
                sender: address(0x1234),
                nonce: 0,
                initCode: "",
                callData: abi.encodePacked(selector, bytes28(0)),
                accountGasLimits: accountGasLimits,
                preVerificationGas: 0,
                gasFees: bytes32(0),
                paymasterAndData: "",
                signature: ""
            });
    }
}
