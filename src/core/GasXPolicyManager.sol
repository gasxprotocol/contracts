// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";

/**
 * @title  GasXPolicyManager
 * @author GasX
 * @notice The minimal on-chain enforcement that closes the paymaster-drain finding: per-campaign
 *         budget/spent/active state that the campaign's BOUND strategy decrements in postOp. Holds the
 *         oracle-signer registry the paymaster trusts. UUPS + Ownable2Step (timelock/multisig owner in
 *         production, spec §8); stable address referenced by all strategies.
 * @dev    Each campaign is bound to exactly one strategy (`Campaign.strategy`); only that strategy may
 *         consume it, so a registered strategy can never spend a campaign it does not own. `consumeUpTo`
 *         is the postOp-safe path (never reverts on the expected exhausted/expired/over-budget cases —
 *         it returns 0/partial — so a postOp can never be forced into PostOpReverted); `consume` is the
 *         strict path for explicit decrements/tests. Both are monotonic and fail-closed.
 */
contract GasXPolicyManager is IGasXPolicyManager, Ownable2StepUpgradeable, UUPSUpgradeable {
    mapping(bytes32 => Campaign) private _campaigns;
    mapping(address => bool) private _strategies;
    mapping(address => bool) private _oracleSigners;

    error NotStrategy();
    error StrategyNotRegistered();
    error CampaignInactive();
    error CampaignExpired();
    error BudgetExceeded();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
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
    /// @inheritdoc IGasXPolicyManager
    function consume(bytes32 id, uint256 feeWei) external {
        Campaign storage c = _campaigns[id];
        if (c.strategy != msg.sender) revert NotStrategy();
        if (!c.active) revert CampaignInactive();
        if (c.endsAt != 0 && block.timestamp > c.endsAt) revert CampaignExpired();
        uint256 newSpent = uint256(c.spentWei) + feeWei;
        if (newSpent > c.budgetWei) revert BudgetExceeded();
        c.spentWei = uint128(newSpent);
        if (newSpent == c.budgetWei) {
            c.active = false;
            emit ActiveSet(id, false);
        }
        emit Consumed(id, msg.sender, feeWei, c.budgetWei - c.spentWei);
    }

    /// @inheritdoc IGasXPolicyManager
    function consumeUpTo(bytes32 id, uint256 feeWei) external returns (uint256 charged) {
        Campaign storage c = _campaigns[id];
        if (c.strategy != msg.sender) revert NotStrategy(); // mis-wire; caught by the strategy's try/catch
        if (!c.active) return 0;
        if (c.endsAt != 0 && block.timestamp > c.endsAt) {
            c.active = false;
            emit ActiveSet(id, false);
            return 0;
        }
        uint256 rem = c.budgetWei > c.spentWei ? c.budgetWei - c.spentWei : 0;
        charged = feeWei < rem ? feeWei : rem;
        if (charged == 0) return 0;
        uint256 newSpent = uint256(c.spentWei) + charged;
        c.spentWei = uint128(newSpent);
        if (newSpent >= c.budgetWei) {
            c.active = false;
            emit ActiveSet(id, false);
        }
        emit Consumed(id, msg.sender, charged, c.budgetWei - c.spentWei);
        return charged;
    }

    // --- admin (owner = timelock/multisig in prod) ---
    function setCampaign(bytes32 id, address strategy, uint128 budgetWei, uint48 endsAt) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (!_strategies[strategy]) revert StrategyNotRegistered();
        Campaign storage c = _campaigns[id];
        c.budgetWei = budgetWei;
        c.endsAt = endsAt;
        c.active = true;
        c.strategy = strategy;
        emit CampaignSet(id, strategy, budgetWei, endsAt);
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
