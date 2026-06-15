// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
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
        // userOpHash is filled by `_bind` once the binding hash over the sig-excluded pad is known.
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

    /// @dev The signature-excluded region (`paymasterAndData[:len-65]`) that the approval binds over.
    ///      Layout matches GasXPaymasterBase._decodeApproval (NO userOpHash — derived on-chain).
    function _signedRegion(GasXPolicyLib.SignedApproval memory a) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pm),
            uint128(300_000),
            uint128(150_000), // 52-byte offset
            a.campaignId,
            a.sender,
            a.maxFeeWei,
            a.validAfter,
            a.validUntil,
            a.eligibilityRef
        );
    }

    /// @dev Binding (Open Q3, RESOLVED): set `a.userOpHash` to the EntryPoint hash of the op whose
    ///      paymasterAndData is the sig-excluded region, exactly as the base derives it.
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
            paymasterAndData: _signedRegion(a),
            signature: ""
        });
        a.userOpHash = ep.getUserOpHash(bindingOp);
        return a;
    }

    function _pad(GasXPolicyLib.SignedApproval memory a, bytes memory sig) internal view returns (bytes memory) {
        return abi.encodePacked(_signedRegion(a), sig);
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
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (bytes memory ctx, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, 0, "valid");
        (bytes32 campaignId, uint256 maxFeeWei) = abi.decode(ctx, (bytes32, uint256));
        assertEq(campaignId, C);
        assertEq(maxFeeWei, 1 ether);
    }

    function test_reverts_when_signer_not_registered() public {
        pm.setTrustedSigner(signer, false); // flip the OWN-storage mirror
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.UnauthorizedSigner.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
    }

    function test_reverts_on_wrong_signer_key() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, 0xBAD)); // not registered
        vm.expectRevert(GasXPaymasterBase.UnauthorizedSigner.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
    }

    function test_reverts_on_expiry() public {
        vm.warp(1000);
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, uint48(999)), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.ApprovalExpired.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
    }

    function test_reverts_before_validAfter() public {
        vm.warp(1000);
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, uint48(2000), type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.ApprovalNotYetValid.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
    }

    function test_reverts_when_maxCost_exceeds_maxFeeWei() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(0.5 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.MaxFeeExceeded.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 1 ether); // maxCost > maxFeeWei
    }

    function test_reverts_on_sender_mismatch() public {
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        PackedUserOperation memory op = _op(pad, 0);
        op.sender = address(0xDEAD); // != signed sender → SenderMismatch (checked before the hash binding)
        vm.expectRevert(GasXPaymasterBase.SenderMismatch.selector);
        pm.exposedValidate(op, OP_HASH, 0.5 ether);
    }

    function test_reverts_on_op_field_tamper_replay() public {
        // Anti-replay: the approval binds to the EntryPoint hash of THIS op (sig-excluded). Replaying the
        // same approval against a different op (changed nonce) yields a different derived userOpHash, so
        // the recovered signer no longer matches → UnauthorizedSigner.
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        vm.expectRevert(GasXPaymasterBase.UnauthorizedSigner.selector);
        pm.exposedValidate(_op(pad, 7), OP_HASH, 0.5 ether); // nonce 7 != bound nonce 0
    }

    function test_reverts_on_short_signed_data() public {
        bytes memory pad = abi.encodePacked(address(pm), uint128(300_000), uint128(150_000), hex"1234");
        vm.expectRevert(GasXPaymasterBase.InvalidSignedDataLength.selector);
        pm.exposedValidate(_op(pad, 0), OP_HASH, 0);
    }

    function test_postOp_consumes_actualGasCost() public {
        bytes memory ctx = abi.encode(C, uint256(1 ether));
        pm.exposedPostOp(ctx, 0.3 ether, 1 gwei);
        assertEq(policy.consumed(C), 0.3 ether, "postOp must consume actualGasCost");
        assertEq(policy.lastFee(), 0.3 ether);
    }

    function test_validation_does_not_touch_policyManager() public {
        policy.setReverts(true); // any cross-contract call into PM during validation would revert
        GasXPolicyLib.SignedApproval memory a = _bind(_approval(1 ether, 0, type(uint48).max), 0);
        bytes memory pad = _pad(a, _sign(a, SIGNER_PK));
        (, uint256 vd) = pm.exposedValidate(_op(pad, 0), OP_HASH, 0.5 ether);
        assertEq(vd, 0, "validation must not read PolicyManager");
    }
}
