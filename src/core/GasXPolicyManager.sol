// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";

/**
 * @title  GasXPolicyManager
 * @author GasX
 * @notice The minimal on-chain enforcement that closes the paymaster-drain finding: per-campaign
 *         budget/spent/active state that registered strategies decrement in postOp via `consume`.
 *         Holds the oracle-signer registry the paymaster trusts. UUPS + Ownable (timelock/multisig
 *         owner in production, spec §8); stable address referenced by all strategies.
 * @dev    `consume` is the only state-mutating path a strategy can reach, and it is monotonic and
 *         fail-closed: it reverts past budget (never negative) and auto-deactivates on exhaustion.
 */
contract GasXPolicyManager is IGasXPolicyManager, OwnableUpgradeable, UUPSUpgradeable {
    mapping(bytes32 => Campaign) private _campaigns;
    mapping(address => bool) private _strategies;
    mapping(address => bool) private _oracleSigners;

    error NotStrategy();
    error CampaignInactive();
    error BudgetExceeded();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    modifier onlyStrategy() {
        if (!_strategies[msg.sender]) revert NotStrategy();
        _;
    }

    // --- views ---
    function campaignOf(bytes32 id) external view returns (Campaign memory) {
        return _campaigns[id];
    }

    function remaining(bytes32 id) public view returns (uint256) {
        Campaign storage c = _campaigns[id];
        return c.budgetWei > c.spentWei ? c.budgetWei - c.spentWei : 0;
    }

    function isOracleSigner(address signer) external view returns (bool) {
        return _oracleSigners[signer];
    }

    // --- enforcement (postOp) ---
    function consume(bytes32 id, uint256 feeWei) external onlyStrategy {
        Campaign storage c = _campaigns[id];
        if (!c.active) revert CampaignInactive();
        uint256 newSpent = uint256(c.spentWei) + feeWei;
        if (newSpent > c.budgetWei) revert BudgetExceeded();
        c.spentWei = uint128(newSpent);
        if (newSpent == c.budgetWei) {
            c.active = false;
            emit ActiveSet(id, false);
        }
        emit Consumed(id, msg.sender, feeWei, c.budgetWei - c.spentWei);
    }

    // --- admin (owner = timelock/multisig in prod) ---
    function setCampaign(bytes32 id, uint128 budgetWei, uint48 endsAt) external onlyOwner {
        Campaign storage c = _campaigns[id];
        c.budgetWei = budgetWei;
        c.endsAt = endsAt;
        c.active = true;
        emit CampaignSet(id, budgetWei, endsAt);
        emit ActiveSet(id, true);
    }

    function setActive(bytes32 id, bool active) external onlyOwner {
        _campaigns[id].active = active;
        emit ActiveSet(id, active);
    }

    function setOracleSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        _oracleSigners[signer] = allowed;
        emit OracleSignerSet(signer, allowed);
    }

    function setStrategy(address strategy, bool allowed) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        _strategies[strategy] = allowed;
        emit StrategySet(strategy, allowed);
    }

    function _authorizeUpgrade(address) internal override onlyOwner { }

    uint256[47] private __gap;
}
