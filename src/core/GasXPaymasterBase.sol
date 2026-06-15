// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation, UserOperationLib } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import "@account-abstraction/contracts/core/BasePaymaster.sol";
import { _packValidationData } from "@account-abstraction/contracts/core/Helpers.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { GasXPolicyLib } from "../libraries/GasXPolicyLib.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";
import { IGasXPaymasterStrategy } from "../interfaces/IGasXPaymasterStrategy.sol";

/**
 * @title  GasXPaymasterBase
 * @author GasX
 * @notice Shared base for every GasX sponsorship strategy. Validation verifies the EIP-712
 *         `SignedApproval` reading ONLY signed data + own storage (no cross-contract read →
 *         ERC-7562/bundler-safe); postOp decrements the campaign budget on the on-chain
 *         `GasXPolicyManager` (cross-contract write is permitted in postOp). `maxFeeWei` is the
 *         validation-time guard; `consumeUpTo(actualGasCost)` is the accounting truth. This split is
 *         what closes the paymaster-drain finding without violating AA validation rules (spec §5).
 *
 * @dev    Security posture (post-audit):
 *         - Time window + signature result are RETURNED as packed `validationData`, never reverted, so
 *           the EntryPoint enforces the window (AA32) and bundler simulation/estimation is not bricked.
 *           Only data-integrity violations (sender mismatch / maxFee / malformed length / under-provisioned
 *           postOp gas) revert in validation — those are deterministic on the op's own fields.
 *         - Signer membership is checked against the paymaster's OWN `_trustedSigners` mirror (ERC-7562:
 *           no cross-contract read in validation). `tryRecover` makes a malformed sig fail closed (sigFailed).
 *         - Binding (non-circular): the approval `userOpHash` is DERIVED on-chain as
 *           `entryPoint().getUserOpHash(op with paymasterAndData[:len-65])` — calling the EntryPoint's
 *           getUserOpHash in validation is ERC-7562-allowed (it is the v0.9 EIP-712 toTypedDataHash over
 *           domain {name:'ERC4337',version:'1',chainid,entryPoint}); do NOT replace it with the legacy
 *           keccak256(abi.encode(hash,ep,chainid)) form.
 *         - postOp uses non-reverting `consumeUpTo` inside try/catch so an exhausted/expired campaign (or a
 *           paused/upgraded PolicyManager) can never force PostOpReverted (gas paid, budget not decremented).
 *         The paymaster is intentionally NOT upgradeable (a proxy holding an EntryPoint deposit is a drain surface).
 */
abstract contract GasXPaymasterBase is BasePaymaster, EIP712, IGasXPaymasterStrategy {
    using GasXPolicyLib for GasXPolicyLib.SignedApproval;

    /// @notice The on-chain budget store this strategy decrements in postOp.
    address public immutable policyManagerAddr;

    /// @dev Packed signed-data region after PAYMASTER_DATA_OFFSET, excluding the derived userOpHash
    ///      (derived on-chain) and the trailing signature: 32 + 20 + 32 + 6 + 6 + 32 = 128 bytes.
    uint256 internal constant SIGNED_DATA_SIZE = 128;
    uint256 internal constant SIG_SIZE = 65;
    /// @dev Floor for the op's paymasterPostOpGasLimit (bytes [36:52]) so consume() cannot OOG in postOp.
    ///      Complementary to the postOp try/catch — the try/catch is the real protection.
    uint256 internal constant MIN_POSTOP_GAS = 40_000;

    /// @dev Own-storage oracle-signer mirror — validation reads only this (ERC-7562: no cross-contract read).
    mapping(address => bool) private _trustedSigners;

    error InvalidSignedDataLength();
    error MaxFeeExceeded();
    error SenderMismatch();
    error PostOpGasTooLow();
    error ZeroAddress();

    event ConsumeFailed(bytes32 indexed campaignId, uint256 feeWei);

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
    /// @dev Returns the bound EntryPoint as an address (BasePaymaster exposes `entryPoint()` returning
    ///      IEntryPoint; named `entryPointAddress` to avoid the getter clash — resolved Open Q5).
    function entryPointAddress() external view returns (address) {
        return address(entryPoint());
    }

    function strategyId() external view virtual returns (bytes32);
    function supportsCampaign(bytes32 campaignId) external view virtual returns (bool);

    /// @notice Owner mirrors the PolicyManager oracle-signer set into own storage so validation reads only
    ///         own storage. REVOCATION ordering is fail-closed: revoke here on each strategy before/at the
    ///         same time as GasXPolicyManager.setOracleSigner(false). Emits an event so mirror drift vs
    ///         OracleSignerSet is observable off-chain. Resolved Open Q4.
    function setTrustedSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        _trustedSigners[signer] = allowed;
        emit TrustedSignerSet(signer, allowed);
    }

    function isTrustedSigner(address signer) external view returns (bool) {
        return _trustedSigners[signer];
    }

    // --- validation (ERC-7562: only signed data + own storage) ---
    // NOT `view`: strategies may write in validation (e.g. ERC20 pre-charge, Task 9). The only external
    // call is entryPoint().getUserOpHash on the paymaster's own immutable, trusted EntryPoint (ERC-7562-ok).
    function _validatePaymasterUserOp(PackedUserOperation calldata op, bytes32, uint256 maxCost)
        internal
        virtual
        override
        returns (bytes memory context, uint256 validationData)
    {
        (GasXPolicyLib.SignedApproval memory a, bytes calldata sig) = _decodeApproval(op.paymasterAndData);

        // Data-integrity reverts (deterministic on the op's own fields — safe to revert in validation).
        if (a.sender != op.sender) revert SenderMismatch();
        uint256 postOpGas = uint128(bytes16(op.paymasterAndData[36:52]));
        if (postOpGas < MIN_POSTOP_GAS) revert PostOpGasTooLow();

        // Derive (do not trust a stored value) the bound userOpHash over the signature-excluded region.
        a.userOpHash = _bindingUserOpHash(op);

        if (maxCost > a.maxFeeWei) revert MaxFeeExceeded();

        // Soft results (returned as validationData so the EntryPoint enforces them; never revert here).
        address recovered = GasXPolicyLib.tryRecover(_domainSeparatorV4(), a, sig);
        bool sigFailed = !_trustedSigners[recovered];

        context = abi.encode(a.campaignId, a.sender, a.userOpHash);
        return (context, _packValidationData(sigFailed, a.validUntil, a.validAfter));
    }

    // --- postOp (cross-contract write permitted; never reverts upward) ---
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256)
        internal
        virtual
        override
    {
        if (mode != PostOpMode.opSucceeded) return;
        (bytes32 campaignId, address sender, bytes32 userOpHash) = abi.decode(context, (bytes32, address, bytes32));
        // consumeUpTo is non-reverting on expected cases; try/catch also absorbs an unexpected revert
        // (paused/upgraded PolicyManager) so a postOp can never bubble PostOpReverted.
        try IGasXPolicyManager(policyManagerAddr).consumeUpTo(campaignId, actualGasCost) returns (uint256 charged) {
            emit GasXSponsored(campaignId, sender, userOpHash, charged);
        } catch {
            emit ConsumeFailed(campaignId, actualGasCost);
        }
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

    // --- decode (exact length; userOpHash is NOT in the pad — derived on-chain) ---
    function _decodeApproval(bytes calldata pData)
        internal
        pure
        returns (GasXPolicyLib.SignedApproval memory a, bytes calldata sig)
    {
        bytes calldata data = pData[PAYMASTER_DATA_OFFSET:];
        // Exact length so `pad[:len-65]` provably equals "everything except the sig" (closes desync).
        if (data.length != SIGNED_DATA_SIZE + SIG_SIZE) revert InvalidSignedDataLength();
        a.campaignId = bytes32(data[0:32]);
        a.sender = address(bytes20(data[32:52]));
        a.maxFeeWei = uint256(bytes32(data[52:84]));
        a.validAfter = uint48(bytes6(data[84:90]));
        a.validUntil = uint48(bytes6(data[90:96]));
        a.eligibilityRef = bytes32(data[96:128]);
        // a.userOpHash intentionally left zero here; set by _bindingUserOpHash in validation.
        sig = data[SIGNED_DATA_SIZE:SIGNED_DATA_SIZE + SIG_SIZE];
    }
}
