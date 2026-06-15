// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GasXPolicyLib } from "../src/libraries/GasXPolicyLib.sol";

contract GasXPolicyLibFuzzTest is Test {
    // Mirror of OZ EIP712 domain separator for a fixed (name,version,chainId,verifyingContract).
    bytes32 internal constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(TYPE_HASH, keccak256(bytes("GasX")), keccak256(bytes("1")), block.chainid, verifyingContract)
        );
    }

    function _approval(bytes32 campaignId, address sender, bytes32 opHash)
        internal
        pure
        returns (GasXPolicyLib.SignedApproval memory a)
    {
        a = GasXPolicyLib.SignedApproval({
            campaignId: campaignId,
            sender: sender,
            userOpHash: opHash,
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: type(uint48).max,
            eligibilityRef: bytes32(uint256(0xE11))
        });
    }

    function testFuzz_typehash_is_frozen() public pure {
        assertEq(
            GasXPolicyLib.APPROVAL_TYPEHASH,
            keccak256(
                "SignedApproval(bytes32 campaignId,address sender,bytes32 userOpHash,uint256 maxFeeWei,uint48 validAfter,uint48 validUntil,bytes32 eligibilityRef)"
            ),
            "typehash drift"
        );
    }

    function testFuzz_recover_roundtrips(uint256 pk, bytes32 campaignId, address sender, bytes32 opHash) public {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        address signer = vm.addr(pk);
        bytes32 ds = _domainSeparator(address(this));
        GasXPolicyLib.SignedApproval memory a = _approval(campaignId, sender, opHash);

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(GasXPolicyLib.recover(ds, a, sig), signer, "recover mismatch");
    }

    function testFuzz_domain_isolation_breaks_recovery(uint256 pk, bytes32 opHash) public {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        address signer = vm.addr(pk);
        GasXPolicyLib.SignedApproval memory a = _approval(bytes32(0), address(0xBEEF), opHash);

        bytes32 dsA = _domainSeparator(address(0xAAAA));
        bytes32 digestA = keccak256(abi.encodePacked("\x19\x01", dsA, GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digestA);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 dsB = _domainSeparator(address(0xBBBB));
        assertTrue(GasXPolicyLib.recover(dsB, a, sig) != signer, "domain not isolating replay");
    }

    function test_recover_reverts_on_short_sig() public {
        GasXPolicyLib.SignedApproval memory a = _approval(bytes32(0), address(0xBEEF), bytes32(0));
        bytes memory shortSig = hex"1234";
        bytes32 ds = _domainSeparator(address(this));
        vm.expectRevert(); // OZ ECDSAInvalidSignatureLength
        this.callRecover(ds, a, shortSig);
    }

    function callRecover(bytes32 ds, GasXPolicyLib.SignedApproval calldata a, bytes calldata sig)
        external
        pure
        returns (address)
    {
        return GasXPolicyLib.recover(ds, a, sig);
    }

    function testFuzz_tryRecover_roundtrips(uint256 pk, bytes32 opHash) public {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        address signer = vm.addr(pk);
        bytes32 ds = _domainSeparator(address(this));
        GasXPolicyLib.SignedApproval memory a = _approval(bytes32(0), address(0xBEEF), opHash);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, GasXPolicyLib.hash(a)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        assertEq(GasXPolicyLib.tryRecover(ds, a, abi.encodePacked(r, s, v)), signer, "tryRecover mismatch");
    }

    function test_tryRecover_returns_zero_on_malformed_sig() public view {
        GasXPolicyLib.SignedApproval memory a = _approval(bytes32(0), address(0xBEEF), bytes32(0));
        bytes32 ds = _domainSeparator(address(this));
        // short sig must NOT revert (unlike recover) — it returns address(0) so validation fails closed.
        assertEq(GasXPolicyLib.tryRecover(ds, a, hex"1234"), address(0), "malformed sig must yield address(0)");
    }
}
