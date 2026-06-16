// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";

/**
 * @title  GasXPolicyManager
 * @author GasX
 * @notice On-chain aggregate spend-ceiling: per-campaign budget/spent/active state that the campaign's
 *         BOUND strategy decrements in postOp. N independent wallets sharing one campaign draw down one
 *         budget, fail-closed. Authority is split by RISK DIRECTION (see IGasXPolicyManager trust model):
 *         the OWNER (a TimelockController in production) can only RAISE/extend/register/upgrade — delayed
 *         and public; a separate GUARDIAN can only LOWER/deactivate/pause — instant, never increases spend
 *         and never upgrades. So the operator cannot raise or replace enforcement unilaterally, silently,
 *         or instantly. NOT "unbreakable": a colluding k-of-n owner can still upgrade after the timelock
 *         delay, and the budget is GAS-denominated (it does not cap stablecoin value — that is a separate
 *         value-ceiling path).
 * @dev    `consumeUpTo` is the postOp-safe path (never reverts on expected exhausted/expired/over-budget/
 *         paused cases — returns 0/partial); `consume` is the strict path. Both are monotonic + fail-closed.
 */
contract GasXPolicyManager is IGasXPolicyManager, Ownable2StepUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    mapping(bytes32 => Campaign) private _campaigns;
    mapping(address => bool) private _strategies;
    mapping(address => bool) private _oracleSigners;
    address private _guardian; // instant-only safety role: lower / deactivate / pause. Never raises or upgrades.

    error NotStrategy();
    error StrategyNotRegistered();
    error CampaignInactive();
    error CampaignExpired();
    error BudgetExceeded();
    error ZeroAddress();
    error NotGuardian();
    error CampaignExists();
    error UnknownCampaign();
    error BudgetNotIncreased();
    error InvalidLowerBudget();
    error NotExtended();

    modifier onlyGuardian() {
        if (msg.sender != _guardian) revert NotGuardian();
        _;
    }

    /// @dev Instant safety actions (deactivate / pause) are allowed to the guardian OR the owner.
    modifier onlyGuardianOrOwner() {
        if (msg.sender != _guardian && msg.sender != owner()) revert NotGuardian();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __Pausable_init();
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

    function guardian() external view returns (address) {
        return _guardian;
    }

    // --- enforcement (postOp) ---
    /// @inheritdoc IGasXPolicyManager
    function consume(bytes32 id, uint256 feeWei) external whenNotPaused {
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
        if (paused()) return 0; // fail-closed but postOp-safe: never revert
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

    // --- campaign lifecycle ---
    /// @inheritdoc IGasXPolicyManager
    /// @dev Creation-only: reverts if the id already exists, so a budget can never be silently raised by
    ///      re-setting. Raises go through `raiseBudget` (timelocked owner); lowers through `lowerBudget`.
    function setCampaign(bytes32 id, address strategy, uint128 budgetWei, uint48 endsAt) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (!_strategies[strategy]) revert StrategyNotRegistered();
        Campaign storage c = _campaigns[id];
        if (c.strategy != address(0)) revert CampaignExists();
        c.budgetWei = budgetWei;
        c.endsAt = endsAt;
        c.active = true;
        c.strategy = strategy;
        emit CampaignSet(id, strategy, budgetWei, endsAt);
        emit ActiveSet(id, true);
    }

    /// @inheritdoc IGasXPolicyManager
    function raiseBudget(bytes32 id, uint128 newBudgetWei) external onlyOwner {
        Campaign storage c = _campaigns[id];
        if (c.strategy == address(0)) revert UnknownCampaign();
        if (newBudgetWei <= c.budgetWei) revert BudgetNotIncreased(); // monotonic up; owner==timelock => delayed+public
        c.budgetWei = newBudgetWei;
        emit BudgetRaised(id, newBudgetWei);
    }

    /// @inheritdoc IGasXPolicyManager
    function lowerBudget(bytes32 id, uint128 newBudgetWei) external onlyGuardian {
        Campaign storage c = _campaigns[id];
        if (c.strategy == address(0)) revert UnknownCampaign();
        if (newBudgetWei > c.budgetWei || newBudgetWei < c.spentWei) revert InvalidLowerBudget(); // down only, never below spent
        c.budgetWei = newBudgetWei;
        emit BudgetLowered(id, newBudgetWei);
    }

    /// @inheritdoc IGasXPolicyManager
    function extendCampaign(bytes32 id, uint48 newEndsAt) external onlyOwner {
        Campaign storage c = _campaigns[id];
        if (c.strategy == address(0)) revert UnknownCampaign();
        // Extend only: newEndsAt==0 removes the expiry; otherwise it must be strictly later than a finite endsAt.
        if (newEndsAt != 0 && (c.endsAt == 0 || newEndsAt <= c.endsAt)) revert NotExtended();
        c.endsAt = newEndsAt;
        emit CampaignExtended(id, newEndsAt);
    }

    /// @inheritdoc IGasXPolicyManager
    function deactivate(bytes32 id) external onlyGuardianOrOwner {
        _campaigns[id].active = false;
        emit ActiveSet(id, false);
    }

    /// @inheritdoc IGasXPolicyManager
    function reactivate(bytes32 id) external onlyOwner {
        if (_campaigns[id].strategy == address(0)) revert UnknownCampaign();
        _campaigns[id].active = true;
        emit ActiveSet(id, true);
    }

    // --- registries (owner = timelock) ---
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

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        _guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    // --- global safety ---
    /// @inheritdoc IGasXPolicyManager
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @inheritdoc IGasXPolicyManager
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Upgrades are owner-gated; in production the owner is a TimelockController, so every upgrade is
    ///      delayed and publicly visible. The guardian is NOT the owner and can never upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner { }

    uint256[46] private __gap; // was [47]; debited by 1 for `_guardian`
}
