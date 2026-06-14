// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/GasXERC20FeePaymaster.sol";

/// @title TestableGasXERC20
/// @notice Exposes internal GasXERC20FeePaymaster functions for unit testing purposes.
contract TestableGasXERC20 is GasXERC20FeePaymaster {
    constructor(
        IEntryPoint _entryPoint,
        address _feeToken,
        address _priceQuoteBaseToken,
        address _priceOracle,
        address _initialOracleSigner,
        uint256 _minFee,
        uint256 _feeMarkupBps
    )
        GasXERC20FeePaymaster(
            _entryPoint,
            _feeToken,
            _priceQuoteBaseToken,
            _priceOracle,
            _initialOracleSigner,
            _minFee,
            _feeMarkupBps
        )
    {}

    /// @notice Exposes internal _calculateFee function for testing
    function exposedCalculateFee(uint256 gasCost, uint256 price) external view returns (uint256) {
        return _calculateFee(gasCost, price);
    }

    /// @notice Exposes internal _estimateFee function for testing
    function exposedEstimateFee(uint256 gasCost) external view returns (uint256) {
        return _estimateFee(gasCost);
    }

    /// @notice Exposes internal _verifyUserFunds function for testing
    function exposedVerifyUserFunds(address user, uint256 requiredFee) external view {
        _verifyUserFunds(user, requiredFee);
    }

    /// @notice Exposes postOp for testing (success mode)
    function exposedPostOp(bytes calldata context, uint256 actualGasCost, uint256 userOpGasPrice) external {
        _postOp(PostOpMode.opSucceeded, context, actualGasCost, userOpGasPrice);
    }

    /// @notice Exposes postOp for testing (failed mode)
    function exposedPostOpFailed(bytes calldata context, uint256 actualGasCost, uint256 userOpGasPrice) external {
        _postOp(PostOpMode.opReverted, context, actualGasCost, userOpGasPrice);
    }

    /// @notice Exposes _validatePaymasterUserOp for testing
    function exposedValidate(
        PackedUserOperation calldata op,
        bytes32 opHash,
        uint256 maxCost
    ) external view returns (bytes memory ctx, uint256 vd) {
        return _validatePaymasterUserOp(op, opHash, maxCost);
    }
}
