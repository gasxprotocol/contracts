// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../oracles/MultiOracleAggregator.sol";

/**
 * @title MultiOracleAggregatorV2
 * @notice Example of a V2 upgrade.
 * @dev Adds a version function. No new state variables are added,
 * so the initializer can be empty.
 */
contract MultiOracleAggregatorV2 is MultiOracleAggregator {
    /// @custom:oz-upgrades-unsafe-allow missing-initializer
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the V2 contract after an upgrade.
     * @dev The reinitializer(2) guard prevents this from being called more than once.
     * Since no new state variables are introduced in V2, the body is empty.
     * The state from V1 (like the owner) is already preserved in the proxy storage.
     * @custom:oz-upgrades-validate-as-initializer
     */
    function initializeV2() public reinitializer(2) {
        // __Ownable_init_unchained(address(0xdeadbeef));
        __Ownable_init_unchained(owner());
        __UUPSUpgradeable_init_unchained();
    }

    /**
     * @notice Returns the current contract version.
     * @return The version string "V2".
     */
    function version() public pure returns (string memory) {
        return "V2";
    }
}
