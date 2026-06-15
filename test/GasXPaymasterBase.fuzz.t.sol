// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { _packValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { GasXPaymasterBase } from "../src/core/GasXPaymasterBase.sol";
import { GasXPolicyLib } from "../src/libraries/GasXPolicyLib.sol";
import { GasXConformancePaymaster, MockGasXPolicyManager } from "../src/testutils/GasXConformanceHarness.sol";

/// @dev Minimal EntryPoint mock sufficient for BasePaymaster constructor + binding-hash recompute.
contract MockEntryPoint {
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

    /// @dev Deterministic stand-in for v0.9 getUserOpHash over the (sig-excluded) binding op.
    function getUserOpHash(PackedUserOperation memory op) external pure returns (bytes32) {
        return keccak256(abi.encode(op.sender, op.nonce, op.callData, op.paymasterAndData));
    }
}

contract GasXPaymasterBaseFuzzTest is Test {
    GasXConformancePaymaster internal pm;
    MockGasXPolicyManager internal policy;
    MockEntryPoint internal ep;

    uint256 internal constant SIGNER_PK = 0x516;
    address internal signer;
    bytes32 internal constant C = keccak256("campaign.alpha");
    bytes32 internal constant OP_HASH = keccak256("op.alpha");
    address internal constant SENDER = address(0x5EED);
    uint48 internal constant MAXT = type(uint48).max;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        ep = new MockEntryPoint();
        policy = new MockGasXPolicyManager();
        pm = new GasXConformancePaymaster(IEntryPoint(address(ep)), address(policy));
        policy.setSigner(signer, true); // models the PolicyManager registry (not read in validation)
        pm.setTrustedSigner(signer, true); // the OWN-storage mirror the base actually reads (Open Q4)
    }

    function _domainSeparator() internal view returns (bytes32) {
        bytes32 TYPE_HASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return
            keccak256(
                abi.encode(TYPE_HASH, keccak256(bytes("GasX")), keccak256(bytes("1")), block.chainid, address(pm))
            );
    }

    function _approval(uint256 maxFeeWei, uint48 validAfter, uint48 validUntil)
        internal
        pure
        returns (GasXPolicyLib.SignedApproval memory a)
    {
        a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: SENDER,
            userOpHash: bytes32(0),
            maxFeeWei: maxFeeWei,
            validAfter: validAfter,
            validUntil: validUntil,
            eligibilityRef: bytes32(uint256(0xE11))
        });
    }

    function _sign(GasXPolicyLib.SignedApproval memory a, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The signature-excluded region (`paymasterAndData[:len-65]`) the approval binds over.
    ///      Layout matches GasXPaymasterBase._decodeApproval (NO userOpHash — derived on-chain).
    function _region(GasXPolicyLib.SignedApproval memory a, uint128 postOpGas) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pm),
            uint128(300_000),
            postOpGas, // bytes [36:52] = paymasterPostOpGasLimit
            a.campaignId,
            a.sender,
            a.maxFeeWei,
            a.validAfter,
            a.validUntil,
            a.eligibilityRef
        );
    }

    function _bind(GasXPolicyLib.SignedApproval memory a, uint256 nonce)
        internal
        view
        returns (GasXPolicyLib.SignedApproval memory)
    {
        PackedUserOperation memory bindingOp = PackedUserOperation({
            sender: SENDER,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: _region(a, 150_000),
            signature: ""
        });
        a.userOpHash = ep.getUserOpHash(bindingOp);
        return a;
    }

    function _pad(GasXPolicyLib.SignedApproval memory a, bytes memory sig) internal view returns (bytes memory) {
        return abi.encodePacked(_region(a, 150_000), sig);
    }

    function _op(bytes memory pad, uint256 nonce) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: SENDER,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: pad,
            signature: ""
        });
    }

    function test_happy_path_validates_and_packs_context() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (bytes memory ctx, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0), "valid: sigOk + window");
        (bytes32 campaignId, address sender, bytes32 userOpHash) = abi.decode(ctx, (bytes32, address, bytes32));
        assertEq(campaignId, C);
        assertEq(sender, SENDER, "context carries the real sender (not the EntryPoint)");
        assertEq(userOpHash, a.userOpHash, "context carries the bound userOpHash");
    }

    function test_sigFailed_when_signer_not_registered() public {
        pm.setTrustedSigner(signer, false);
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(true, MAXT, 0), "unregistered signer => SIG_VALIDATION_FAILED, no revert");
    }

    function test_sigFailed_on_wrong_signer_key() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, 0xBAD));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(true, MAXT, 0), "wrong key => sigFailed");
    }

    function test_sigFailed_on_malformed_sig_does_not_revert() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, new bytes(65)); // all-zero 65-byte sig => tryRecover yields address(0)
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(true, MAXT, 0), "malformed sig fails closed, no revert");
    }

    function test_returns_window_for_expired_instead_of_reverting() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, uint48(999)), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, 999, 0), "validUntil returned for EntryPoint to enforce (AA32)");
    }

    function test_returns_window_for_not_yet_valid() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, uint48(2000), MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, MAXT, 2000), "validAfter returned, not reverted");
    }

    function test_reverts_when_maxCost_exceeds_maxFeeWei() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(0.5 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.MaxFeeExceeded.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 1 ether);
    }

    function test_reverts_on_sender_mismatch() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        PackedUserOperation memory op = _op(pad, 0);
        op.sender = address(0xDEAD);
        vm.expectRevert(GasXPaymasterBase.SenderMismatch.selector);
        pm.exposedValidate(op, OP_HASH, 0.5 ether);
    }

    function test_replay_other_op_fails_signature() public {
        // The approval binds to THIS op's hash (sig-excluded). Replay against nonce 7 => different derived
        // userOpHash => recovered != trusted signer => sigFailed (soft), not a revert.
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 7), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(true, MAXT, 0), "replay against another op => sigFailed");
    }

    function test_reverts_on_short_signed_data() public {
        bytes memory pad = abi.encodePacked(address(pm), uint128(300_000), uint128(150_000), hex"1234");
        vm.expectRevert(GasXPaymasterBase.InvalidSignedDataLength.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0);
    }

    function test_reverts_on_low_postop_gas() public {
        GasXPolicyLib.SignedApproval memory a = _approval(1 ether, 0, MAXT);
        bytes memory pad = abi.encodePacked(_region(a, 1000), new bytes(65)); // postOpGas 1000 < MIN_POSTOP_GAS
        vm.expectRevert(GasXPaymasterBase.PostOpGasTooLow.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
    }

    function test_postOp_consumes_actualGasCost() public {
        bytes memory ctx = abi.encode(C, SENDER, bytes32("uoh"));
        pm.exposedPostOp(ctx, 0.3 ether, 1 gwei);
        assertEq(policy.consumed(C), 0.3 ether, "postOp must consume actualGasCost");
        assertEq(policy.lastFee(), 0.3 ether);
    }

    function test_postOp_does_not_revert_when_consume_reverts() public {
        policy.setReverts(true); // PolicyManager paused/upgraded/exhausted -> consumeUpTo reverts
        bytes memory ctx = abi.encode(C, SENDER, bytes32("uoh"));
        pm.exposedPostOp(ctx, 0.3 ether, 1 gwei); // must NOT revert (try/catch) -> no PostOpReverted grief
        assertEq(policy.consumed(C), 0, "consume reverted; nothing recorded but postOp survived");
    }

    function test_validation_does_not_touch_policyManager() public {
        policy.setReverts(true); // any cross-contract call into PM during validation would revert
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, MAXT), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, _packValidationData(false, MAXT, 0), "validation must not read PolicyManager");
    }
}
