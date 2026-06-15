// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/GasXWhitelistPaymaster.sol";
import "../src/testutils/TestableGasX.sol";
import { MockGasXPolicyManager } from "../src/testutils/GasXConformanceHarness.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";

/// @title Mock EntryPoint for testing (guard tests revert before the base touches paymasterAndData).
contract MockEntryPoint {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function depositTo(address) external payable { }
    function withdrawTo(address payable, uint256) external { }

    function getDepositInfo(address) external pure returns (uint256, bool, uint112, uint32, uint48) {
        return (0, false, 0, 0, 0);
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable { }
    function unlockStake() external { }
    function withdrawStake(address payable) external { }
}

/**
 * @title GasXWhitelistPaymaster guard/admin fuzz tests
 * @notice Covers the selector whitelist + gas ceiling + pause GUARDS (which run before the base
 *         signed-approval check) and the admin surface. The full signed-policy happy path + postOp
 *         budget consume live in GasXWhitelistPaymaster.signedpolicy.fuzz.t.sol.
 */
contract GasXWhitelistPaymasterFuzzTest is Test {
    TestableGasX public paymaster;
    MockGasXPolicyManager public policy;
    MockEntryPoint public entryPoint;
    address public owner;

    uint256 constant MAX_GAS_LIMIT = 30_000_000;
    uint256 constant MAX_USD_LIMIT = 1_000_000e6;

    function setUp() public {
        owner = address(this);
        entryPoint = new MockEntryPoint();
        policy = new MockGasXPolicyManager();
        paymaster = new TestableGasX(address(entryPoint), address(policy), "GasX", "1");
    }

    // --- guards (reject before the base signed-approval check) ---

    function testFuzz_GasLimitExceeded_reverts(uint256 setLimit, uint256 opGasLimit) public {
        setLimit = bound(setLimit, 1, MAX_GAS_LIMIT - 1);
        opGasLimit = bound(opGasLimit, setLimit + 1, MAX_GAS_LIMIT);
        bytes4 selector = bytes4(keccak256("testFunction()"));
        paymaster.setLimit(setLimit, 0);
        paymaster.setSelector(selector, true); // whitelisted so the GAS guard is the one that trips
        PackedUserOperation memory op = _createBaseUserOp(selector, opGasLimit);
        vm.expectRevert("GasX: Gas limit exceeded");
        paymaster.exposedValidate(op, bytes32(0), 0);
    }

    function testFuzz_DisallowedSelector_reverts(bytes4 selector) public {
        paymaster.setLimit(MAX_GAS_LIMIT, 0); // gas is fine; selector is the trip
        // selector NOT whitelisted
        PackedUserOperation memory op = _createBaseUserOp(selector, 100_000);
        vm.expectRevert("GasX: Disallowed function");
        paymaster.exposedValidate(op, bytes32(0), 0);
    }

    function testFuzz_SelectorToggle(bytes4 selector, uint8 toggleCount) public {
        toggleCount = uint8(bound(toggleCount, 1, 10));
        bool expectedState = false;
        for (uint8 i = 0; i < toggleCount; i++) {
            expectedState = !expectedState;
            paymaster.setSelector(selector, expectedState);
            assertEq(paymaster.allowedSelectors(selector), expectedState);
        }
    }

    function testFuzz_SetLimits(uint256 maxGas, uint256 maxUsd) public {
        maxGas = bound(maxGas, 0, MAX_GAS_LIMIT);
        maxUsd = bound(maxUsd, 0, MAX_USD_LIMIT);
        vm.expectEmit(true, true, true, true);
        emit GasXWhitelistPaymaster.LimitsUpdated(maxGas, maxUsd);
        paymaster.setLimit(maxGas, maxUsd);
        (uint256 storedGas, uint256 storedUsd) = paymaster.limits();
        assertEq(storedGas, maxGas, "maxGas should match");
        assertEq(storedUsd, maxUsd, "maxUsd should match");
    }

    function testFuzz_PauseBlocksValidation(bytes4 selector, uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 1, 1_000_000);
        paymaster.setLimit(gasLimit, 0);
        paymaster.setSelector(selector, true);
        paymaster.pause();
        PackedUserOperation memory op = _createBaseUserOp(selector, gasLimit);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        paymaster.exposedValidate(op, bytes32(0), 0);
    }

    function testFuzz_OnlyOwnerCanAdmin(address attacker) public {
        vm.assume(attacker != owner);
        vm.startPrank(attacker);
        vm.expectRevert();
        paymaster.setLimit(100, 0);
        vm.expectRevert();
        paymaster.setSelector(bytes4(0x12345678), true);
        vm.expectRevert();
        paymaster.pause();
        vm.expectRevert();
        paymaster.setTrustedSigner(attacker, true);
        vm.stopPrank();
    }

    // --- helpers ---

    function _createBaseUserOp(bytes4 selector, uint256 callGasLimit)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        bytes32 accountGasLimits = bytes32((uint256(0) << 128) | uint256(callGasLimit));
        return PackedUserOperation({
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
