// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockTarget {
    uint256 public counter;

    function execute() external {
        counter++;
    }
}
