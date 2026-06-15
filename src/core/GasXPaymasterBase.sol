// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation, UserOperationLib } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import "@account-abstraction/contracts/core/BasePaymaster.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { GasXPolicyLib } from "../libraries/GasXPolicyLib.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";
import { IGasXPaymasterStrategy } from "../interfaces/IGasXPaymasterStrategy.sol";

/**
 * @title  GasXPaymasterBase
 * @author GasX
 * @notice Shared base for every GasX sponsorship strategy. Validation verifies the EIP-712
 *         `SignedApproval` reading ONLY the signed data + own storage (no cross-contract read →
 *         ERC-7562/bundler-safe); postOp decrements the campaign budget on the on-chain
 *         `GasXPolicyManager` (cross-contract write is permitted in postOp). `maxFeeWei` is the
 *         validation-time guard; `consume(actualGasCost)` is the accounting truth. This split is
 *         what closes the paymaster-drain finding without violating AA validation rules (spec §5).
 * @dev    Strategies inherit and implement `strategyId`/`supportsCampaign`. The paymaster is
 *         intentionally NOT upgradeable (a proxy holding an EntryPoint deposit is a drain surface).
 *
 *         Binding scheme (canonical verifying-paymaster, non-circular): the approval's `userOpHash`
 *         is NOT stored in `paymasterAndData` — it is DERIVED on-chain as the EntryPoint userOpHash
 *         of the op whose `paymasterAndData` is the signature-excluded region (`paymasterAndData[:len-65]`).
 *         Storing it would be self-referential (the field would be inside the bytes it hashes). The
 *         off-chain `GasXOracleSigner` derives the identical hash before signing.
 */
abstract contract GasXPaymasterBase is BasePaymaster, EIP712, IGasXPaymasterStrategy {
    using GasXPolicyLib for GasXPolicyLib.SignedApproval;

    /// @notice The on-chain budget store this strategy decrements in postOp.
    address public immutable policyManagerAddr;

    /// @dev Packed signed-data region after PAYMASTER_DATA_OFFSET, excluding the derived userOpHash
    ///      (derived on-chain) and the trailing signature: 32 + 20 + 32 + 6 + 6 + 32 = 128 bytes.
    uint256 internal constant SIGNED_DATA_SIZE = 128;
    uint256 internal constant SIG_SIZE = 65;

    /// @dev Own-storage oracle-signer mirror — validation reads only this (ERC-7562: no cross-contract read).
    mapping(address => bool) private _trustedSigners;

    error InvalidSignedDataLength();
    error ApprovalExpired();
    error ApprovalNotYetValid();
    error MaxFeeExceeded();
    error UnauthorizedSigner();
    error SenderMismatch();

    constructor(IEntryPoint _entryPoint, address _policyManager, string memory name, string memory version)
        BasePaymaster(_entryPoint, msg.sender)
        EIP712(name, version)
    {
        require(_policyManager != address(0), "GasX: Invalid policyManager");
        policyManagerAddr = _policyManager;
    }

    // --- IGasXPaymasterStrategy ---
    function policyManager() external view returns (address) {
        return policyManagerAddr;
    }

    /// @inheritdoc IGasXPaymasterStrategy
    /// @dev Returns the bound EntryPoint as an address (BasePaymaster's `entryPoint` immutable;
    ///      named `entryPointAddress` to avoid the getter clash — resolved Open Q5).
    function entryPointAddress() external view returns (address) {
        return address(entryPoint());
    }

    function strategyId() external view virtual returns (bytes32);
    function supportsCampaign(bytes32 campaignId) external view virtual returns (bool);

    /// @notice Owner mirrors the PolicyManager oracle-signer set into own storage so validation
    ///         reads only own storage (the admin/multisig that runs `GasXPolicyManager.setOracleSigner`
    ///         calls this on each strategy in the same action). Resolved Open Q4.
    function setTrustedSigner(address signer, bool allowed) external onlyOwner {
        _trustedSigners[signer] = allowed;
    }

    function isTrustedSigner(address signer) external view returns (bool) {
        return _trustedSigners[signer];
    }

    // --- validation (ERC-7562: only signed data + own storage) ---
    // Intentionally NOT `view`: strategies that override may write in validation (e.g. the ERC20
    // strategy pre-charges the fee, Task 9). Validation performs NO cross-contract READ of mutable
    // external state; the only external call is `entryPoint.getUserOpHash` on the paymaster's own
    // immutable, trusted EntryPoint (the bundler's caller), which is staking-exempt.
    function _validatePaymasterUserOp(PackedUserOperation calldata op, bytes32, uint256 maxCost)
        internal
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        (GasXPolicyLib.SignedApproval memory a, bytes calldata sig) = _decodeApproval(op.paymasterAndData);

        if (a.sender != op.sender) revert SenderMismatch();

        // Derive (do not trust a stored value) the bound userOpHash over the signature-excluded
        // region — the canonical, non-circular binding (resolved Open Q3).
        a.userOpHash = _bindingUserOpHash(op);

        if (block.timestamp > a.validUntil) revert ApprovalExpired();
        if (block.timestamp < a.validAfter) revert ApprovalNotYetValid();
        if (maxCost > a.maxFeeWei) revert MaxFeeExceeded();

        address recovered = GasXPolicyLib.recover(_domainSeparatorV4(), a, sig);
        if (!_trustedSigners[recovered]) revert UnauthorizedSigner();

        context = abi.encode(a.campaignId, a.maxFeeWei);
        return (context, 0);
    }

    // --- postOp (cross-contract write permitted) ---
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        internal
        virtual
        override
    {
        if (mode != PostOpMode.opSucceeded) return;
        (bytes32 campaignId,) = abi.decode(context, (bytes32, uint256));
        IGasXPolicyManager(policyManagerAddr).consume(campaignId, actualGasCost);
        emit GasXSponsored(campaignId, msg.sender, bytes32(0), actualGasCost);
    }

    // --- binding hash (exclude the trailing 65-byte approval sig; userOpHash is derived, not stored) ---
    function _bindingUserOpHash(PackedUserOperation calldata op) internal view returns (bytes32) {
        bytes calldata pad = op.paymasterAndData;
        PackedUserOperation memory bindingOp = PackedUserOperation({
            sender: op.sender,
            nonce: op.nonce,
            initCode: op.initCode,
            callData: op.callData,
            accountGasLimits: op.accountGasLimits,
            preVerificationGas: op.preVerificationGas,
            gasFees: op.gasFees,
            paymasterAndData: pad[:pad.length - SIG_SIZE], // exclude the trailing 65-byte approval sig
            signature: "" // EntryPoint userOpHash excludes the account signature regardless
        });
        return entryPoint().getUserOpHash(bindingOp);
    }

    // --- decode (userOpHash is NOT in the pad — derived on-chain) ---
    function _decodeApproval(bytes calldata pData)
        internal
        pure
        returns (GasXPolicyLib.SignedApproval memory a, bytes calldata sig)
    {
        bytes calldata data = pData[PAYMASTER_DATA_OFFSET:];
        if (data.length < SIGNED_DATA_SIZE + SIG_SIZE) revert InvalidSignedDataLength();
        a.campaignId = bytes32(data[0:32]);
        a.sender = address(bytes20(data[32:52]));
        a.maxFeeWei = uint256(bytes32(data[52:84]));
        a.validAfter = uint48(bytes6(data[84:90]));
        a.validUntil = uint48(bytes6(data[90:96]));
        a.eligibilityRef = bytes32(data[96:128]);
        // a.userOpHash intentionally left zero here; set by _bindingUserOpHash in validation.
        sig = data[128:];
    }
}
