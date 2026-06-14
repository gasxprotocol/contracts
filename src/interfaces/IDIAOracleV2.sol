// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDIAOracleV2
 * @notice Minimal interface for accessing DIA on-chain price feeds.
 * @dev Each feed is accessed using a string key (e.g. "ETH/USD").
 *      The oracle returns both the price and the timestamp of last update.
 *      Consumers must handle decimal scaling (usually 1e8) and freshness checks.
 */
interface IDIAOracleV2 {
    /**
     * @notice Retrieves the latest price and timestamp for a given asset pair key
     * @param key The string identifier of the asset pair (e.g. "ETH/USD")
     * @return price The latest price reported by the oracle (typically scaled to 1e8)
     * @return timestamp UNIX timestamp indicating when the price was last updated
     * @dev Consumers should verify that `price > 0` and `block.timestamp - timestamp` is acceptable
     */
    function getValue(string memory key) external view returns (uint128 price, uint128 timestamp);
}
