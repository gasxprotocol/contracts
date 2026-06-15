// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { _packValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { GasXPaymasterBase } from "../src/core/GasXPaymasterBase.sol";
import { GasXPolicyLib } from "../src/libraries/GasXPolicyLib.sol";
import { TestableGasX } from "../src/testutils/TestableGasX.sol";
import { MockGasXPolicyManager } from "../src/testutils/GasXConformanceHarness.sol";

contract MockEP {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function depositTo(address) external payable { }
    function withdrawTo(address payable, uint256) external { }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable { }
    function unlockStake() external { }
    function withdrawStake(address payable) external { }

    function getDepositInfo(address) external pure returns (uint256, bool, uint112, uint32, uint48) {
        return (0, false, 0, 0, 0);
    }

    function getUserOpHash(PackedUserOperation memory op) external pure returns (bytes32) {
        return keccak256(abi.encode(op.sender, op.nonce, op.callData, op.paymasterAndData));
    }
}

/// @notice The whitelist strategy on the hardened base: a whitelisted selector + a valid signed approval
///         validates; selector/gas guards reject up front; postOp consumes the campaign budget.
contract GasXWhitelistSignedPolicyTest is Test {
    TestableGasX internal pm;
    MockGasXPolicyManager internal policy;
    MockEP internal ep;
    uint256 internal constant SIGNER_PK = 0x516;
    address internal signer;
    bytes4 internal constant SEL = 0xb61d27f6; // execute(address,uint256,bytes)
    bytes32 internal constant C = keccak256("campaign.alpha");
    bytes32 internal constant OP_HASH = keccak256("op.alpha");
    address internal constant SENDER = address(0x5EED);
    uint48 internal constant MAXT = type(uint48).max;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        ep = new MockEP();
        policy = new MockGasXPolicyManager();
        pm = new TestableGasX(address(ep), address(policy), "GasX", "1");
        pm.setLimit(10_000_000, 0);
        pm.setSelector(SEL, true);
        pm.setTrustedSigner(signer, true);
    }

    function _ds() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GasX")),
                keccak256(bytes("1")),
                block.chainid,
                address(pm)
            )
        );
    }

    function _region(GasXPolicyLib.SignedApproval memory a) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pm),
            uint128(300_000),
            uint128(150_000),
            a.campaignId,
            a.sender,
            a.maxFeeWei,
            a.validAfter,
            a.validUntil,
            a.eligibilityRef
        );
    }

    function _signedOp(bytes4 sel, uint256 callGasLimit) internal view returns (PackedUserOperation memory op) {
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: SENDER,
            userOpHash: bytes32(0),
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: MAXT,
            eligibilityRef: bytes32(0)
        });
        bytes memory callData = abi.encodePacked(sel, bytes28(0));
        bytes32 accountGasLimits = bytes32(callGasLimit); // low 128 bits = callGasLimit
        // bind over the sig-excluded region (128B, no userOpHash) exactly as the base derives it
        PackedUserOperation memory bindingOp = PackedUserOperation({
            sender: SENDER,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: _region(a),
            signature: ""
        });
        a.userOpHash = ep.getUserOpHash(bindingOp);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _ds(), GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        op = PackedUserOperation({
            sender: SENDER,
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: abi.encodePacked(_region(a), abi.encodePacked(r, s, v)),
            signature: ""
        });
    }

    function test_whitelisted_selector_with_valid_approval_passes() public {
        (bytes memory ctx, uint256 vd) = pm.exposedValidate(_signedOp(SEL, 100_000), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0), "valid signed approval => sig ok + window");
        (bytes32 campaignId, address sender,) = abi.decode(ctx, (bytes32, address, bytes32));
        assertEq(campaignId, C);
        assertEq(sender, SENDER);
    }

    function test_disallowed_selector_reverts_even_with_valid_approval() public {
        // selector guard runs before the base — a non-whitelisted selector is rejected up front.
        // Build the op FIRST: _signedOp makes an external call (getUserOpHash), so it must not sit under expectRevert.
        PackedUserOperation memory op = _signedOp(0xdeadbeef, 100_000);
        vm.expectRevert("GasX: Disallowed function");
        pm.exposedValidate(op, OP_HASH, 0.5 ether);
    }

    function test_gas_ceiling_reverts_even_with_valid_approval() public {
        PackedUserOperation memory op = _signedOp(SEL, 20_000_000); // callGasLimit > 10M limit
        vm.expectRevert("GasX: Gas limit exceeded");
        pm.exposedValidate(op, OP_HASH, 0.5 ether);
    }

    function test_pause_blocks_validation() public {
        PackedUserOperation memory op = _signedOp(SEL, 100_000);
        pm.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pm.exposedValidate(op, OP_HASH, 0.5 ether);
    }

    function test_unpause_restores_validation() public {
        pm.pause();
        pm.unpause();
        (, uint256 vd) = pm.exposedValidate(_signedOp(SEL, 100_000), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0));
    }

    function test_postOp_consumes_budget() public {
        bytes memory ctx = abi.encode(C, SENDER, bytes32("uoh"));
        pm.exposedPostOp(ctx, 0.2 ether, 1 gwei);
        assertEq(policy.consumed(C), 0.2 ether, "postOp consumes actualGasCost via consumeUpTo");
    }
}
