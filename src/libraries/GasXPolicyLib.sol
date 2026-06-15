// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  GasXPolicyLib
 * @author GasX
 * @notice The EIP-712 signed-approval bridge. `SignedApproval` is produced off-chain by
 *         `GasXOracleSigner` after the policy engine validates eligibility + budget, and
 *         verified on-chain by `GasXPaymasterBase` during validation. The domain separator
 *         (chainId + verifying contract) is supplied by the caller, ending cross-deploy replay.
 * @dev    Pure library — no storage, no domain construction here (the paymaster owns the domain
 *         via OZ EIP712). Anti-replay is the `userOpHash` binding; expiry is `validAfter/validUntil`.
 */
library GasXPolicyLib {
    struct SignedApproval {
        bytes32 campaignId;
        address sender;
        bytes32 userOpHash;
        uint256 maxFeeWei;
        uint48 validAfter;
        uint48 validUntil;
        bytes32 eligibilityRef;
    }

    /// @dev Frozen EIP-712 type hash; the off-chain signer MUST use the identical type string.
    bytes32 internal constant APPROVAL_TYPEHASH = keccak256(
        "SignedApproval(bytes32 campaignId,address sender,bytes32 userOpHash,uint256 maxFeeWei,uint48 validAfter,uint48 validUntil,bytes32 eligibilityRef)"
    );

    /// @notice EIP-712 struct hash of a `SignedApproval`.
    function hash(SignedApproval memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                APPROVAL_TYPEHASH,
                a.campaignId,
                a.sender,
                a.userOpHash,
                a.maxFeeWei,
                a.validAfter,
                a.validUntil,
                a.eligibilityRef
            )
        );
    }

    /// @notice Recovers the signer of `a` under `domainSeparator` from a 65-byte ECDSA `sig`.
    /// @dev Reverts via OZ ECDSA on malformed signatures (length / s-malleability / v).
    ///      `sig` is `memory` so both in-test memory buffers and calldata callers compose.
    function recover(bytes32 domainSeparator, SignedApproval memory a, bytes memory sig)
        internal
        pure
        returns (address)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, hash(a)));
        return ECDSA.recover(digest, sig);
    }

    /// @notice Non-reverting recover for use inside ERC-4337 validation: a malformed signature
    ///         (bad length / s-malleability / v) yields `address(0)` instead of reverting, so the
    ///         paymaster can surface SIG_VALIDATION_FAILED via `validationData` rather than bricking
    ///         bundler simulation. `address(0)` is never a trusted signer, so it fails closed.
    function tryRecover(bytes32 domainSeparator, SignedApproval memory a, bytes memory sig)
        internal
        pure
        returns (address)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, hash(a)));
        (address recovered,,) = ECDSA.tryRecover(digest, sig);
        return recovered;
    }
}
