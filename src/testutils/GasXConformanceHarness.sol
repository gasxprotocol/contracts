// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { GasXPaymasterBase } from "../core/GasXPaymasterBase.sol";

/// @notice Minimal concrete strategy over GasXPaymasterBase for testing the base in isolation.
contract GasXConformancePaymaster is GasXPaymasterBase {
    constructor(IEntryPoint ep, address policyManager_) GasXPaymasterBase(ep, policyManager_, "GasX", "1") { }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("gasx.conformance");
    }

    function supportsCampaign(bytes32) external pure override returns (bool) {
        return true;
    }

    // expose internals (NOT view: base validation recomputes the binding hash via the EntryPoint)
    function exposedValidate(PackedUserOperation calldata op, bytes32 opHash, uint256 maxCost)
        external
        returns (bytes memory ctx, uint256 vd)
    {
        return _validatePaymasterUserOp(op, opHash, maxCost);
    }

    function exposedPostOp(bytes calldata ctx, uint256 actualGasCost, uint256 feePerGas) external {
        _postOp(PostOpMode.opSucceeded, ctx, actualGasCost, feePerGas);
    }
}

/// @notice Records consume() calls; mimics GasXPolicyManager's registry for validation tests.
contract MockGasXPolicyManager {
    mapping(address => bool) public isOracleSigner;
    mapping(bytes32 => uint256) public consumed;
    bytes32 public lastCampaign;
    uint256 public lastFee;
    bool public reverts;

    function setSigner(address s, bool ok) external {
        isOracleSigner[s] = ok;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function consume(bytes32 id, uint256 feeWei) external {
        require(!reverts, "PM: revert");
        consumed[id] += feeWei;
        lastCampaign = id;
        lastFee = feeWei;
    }
}
