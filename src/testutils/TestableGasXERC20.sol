// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { GasXERC20FeePaymaster } from "../core/GasXERC20FeePaymaster.sol";

/// @title  TestableGasXERC20 — exposes internal GasXERC20FeePaymaster hooks for unit testing.
contract TestableGasXERC20 is GasXERC20FeePaymaster {
    constructor(
        IEntryPoint _entryPoint,
        address _policyManager,
        string memory name,
        string memory version,
        address _feeToken,
        address _priceOracle,
        address _priceQuoteBaseToken
    )
        GasXERC20FeePaymaster(_entryPoint, _policyManager, name, version, _feeToken, _priceOracle, _priceQuoteBaseToken)
    { }

    function exposedValidate(PackedUserOperation calldata op, bytes32 opHash, uint256 maxCost)
        external
        returns (bytes memory ctx, uint256 vd)
    {
        return _validatePaymasterUserOp(op, opHash, maxCost);
    }

    function exposedPostOp(bytes calldata context, uint256 actualGasCost, uint256 userOpGasPrice) external {
        _postOp(PostOpMode.opSucceeded, context, actualGasCost, userOpGasPrice);
    }

    /// @dev Drive postOp with an explicit mode (parity with the base harness) to prove the budget is
    ///      decremented on opReverted and skipped only on the re-entrant postOpReverted.
    function exposedPostOpWithMode(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 userOpGasPrice
    ) external {
        _postOp(mode, context, actualGasCost, userOpGasPrice);
    }

    function exposedFeeFor(uint256 gasWei, uint256 price) external pure returns (uint256) {
        return _feeFor(gasWei, price);
    }
}
