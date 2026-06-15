// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { GasXWhitelistPaymaster } from "../core/GasXWhitelistPaymaster.sol";

/// @title  TestableGasX — exposes internal GasXWhitelistPaymaster hooks for unit testing.
contract TestableGasX is GasXWhitelistPaymaster {
    constructor(address ep, address policyManager_, string memory name, string memory version)
        GasXWhitelistPaymaster(IEntryPoint(ep), policyManager_, name, version)
    { }

    function exposedValidate(PackedUserOperation calldata op, bytes32 opHash, uint256 maxCost)
        external
        returns (bytes memory ctx, uint256 vd)
    {
        return _validatePaymasterUserOp(op, opHash, maxCost);
    }

    function exposedPostOp(bytes calldata context, uint256 gasCost, uint256 feePerGas) external {
        _postOp(PostOpMode.opSucceeded, context, gasCost, feePerGas);
    }
}
