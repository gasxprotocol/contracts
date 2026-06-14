// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IOracleAggregator
 * @author edsphinx
 * @notice Interface for registering new oracles in a multi-oracle aggregator.
 * @dev Intended to be implemented by contracts like MultiOracleAggregator that support
 *      multiple price feeds per token pair.
 */
interface IOracleAggregator {
    /**
     * @notice Adds a new oracle address for a given token pair.
     * @dev Only callable by an authorized admin or owner, depending on implementation.
     * @param base Address of the base token (e.g. ETH)
     * @param quote Address of the quote token (e.g. USDC)
     * @param oracle Address of the oracle contract implementing IPriceOracle
     */
    function addOracle(address base, address quote, address oracle) external;
}
