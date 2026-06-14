// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDIAOracleV2 } from "../interfaces/IDIAOracleV2.sol";

/// @title MockDIAOracle
/// @notice Mock contract for testing DIAOracleAdapter
contract MockDIAOracle is IDIAOracleV2 {
    mapping(string => uint128) public prices;
    mapping(string => uint128) public timestamps;

    constructor() {}

    function setValue(string memory key, uint128 price, uint128 timestamp) external {
        prices[key] = price;
        timestamps[key] = timestamp;
    }

    function getValue(string memory key) external view override returns (uint128 price, uint128 timestamp) {
        return (prices[key], timestamps[key]);
    }
}
