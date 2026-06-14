// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";

/// @title MockOracle
/// @notice Mock contract for testing MultiOracleAggregator
contract MockOracle is IPriceOracle {
    uint256 private _quote; // Price with 18 decimals
    bool private _shouldRevert;

    constructor(uint256 initialQuote) {
        _quote = initialQuote;
        _shouldRevert = false;
    }

    function setQuote(uint256 newQuote) external {
        _quote = newQuote;
    }

    function setRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    // This version correctly simulates a price by using the input amount.
    function getQuote(uint256 amount, address, address) external view override returns (uint256) {
        require(!_shouldRevert, "MockOracle: forced revert");
        return (amount * _quote) / 1e18;
    }
}
