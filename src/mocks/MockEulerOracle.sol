// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockEulerOracle
/// @notice Mock contract for testing EulerOracleAdapter
/// @dev Implements getPrice() that Euler oracle provides
contract MockEulerOracle {
    uint256 public mockPrice;

    constructor() {
        mockPrice = 1e18; // Default 1:1 price
    }

    function setPrice(uint256 _price) external {
        mockPrice = _price;
    }

    function setMockPrice(uint256 _price) external {
        mockPrice = _price;
    }

    function getPrice(address, address) external view returns (uint256) {
        return mockPrice;
    }
}
