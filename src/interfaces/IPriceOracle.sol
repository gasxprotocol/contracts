// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPriceOracle
 * @author edsphinx
 * @notice Standard interface for retrieving price quotes between token pairs.
 *         Designed for use in modular oracle adapters (Euler, DIA, Chainlink, etc.).
 * @dev All implementations MUST return values scaled to 1e18 to ensure consistency.
 */
interface IPriceOracle {
    /**
     * @notice Returns the equivalent amount of `quote` tokens for a given `inAmount` of `base`.
     * @param inAmount Amount of base token to convert
     * @param base Address of the token being priced
     * @param quote Address of the token used as unit of account
     * @return outAmount Equivalent value in quote token units (scaled to 1e18)
     */
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256 outAmount);
}
