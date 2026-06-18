// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IGasXPolicyManager
 * @author GasX
 * @notice On-chain budget truth for GasX campaigns. The campaign's bound strategy decrements budget
 *         in postOp via `consumeUpTo` (non-reverting) / `consume` (strict); validation never reads
 *         this contract (ERC-7562). Each campaign is bound to exactly one strategy so a registered
 *         strategy can never spend a campaign it does not own.
 * @dev    TRUST MODEL (state it honestly — do not overclaim):
 *         - The oracle-signer registry is an allowlist of trusted EIP-712 signers; each approval is
 *           verified against a SINGLE recovered signer. This is NOT an on-chain k-of-n threshold. The
 *           on-chain budget bounds a compromised signer's blast radius to a campaign's remaining
 *           budget; it does NOT prevent in-budget misappropriation.
 *         - The budget is GAS-denominated (`budgetWei`). It does not cap stablecoin/payment value.
 *         - Authority is split by RISK DIRECTION: the OWNER (a TimelockController in production) is the
 *           only role that can RAISE a budget, extend a campaign, register strategies/signers, or
 *           upgrade — all delayed and publicly visible. A separate GUARDIAN can only LOWER a budget,
 *           deactivate a campaign, or pause — instant, and can never increase spend or upgrade. So the
 *           operator cannot raise or replace enforcement unilaterally, silently, or instantly.
 */
interface IGasXPolicyManager {
    struct Campaign {
        uint128 budgetWei;
        uint128 spentWei;
        uint48 endsAt;
        bool active;
        address strategy; // the only strategy allowed to consume this campaign
    }

    /// @notice B2 — the value (stablecoin/x402) ceiling, parallel to the gas Campaign. Amounts are in
    ///         the token's NATIVE units (e.g. USDC 6dp); there is NO on-chain price conversion. `settler`
    ///         is the only contract allowed to consume it (e.g. the x402 settlement router).
    struct ValueCampaign {
        uint128 valueBudget;
        uint128 valueSpent;
        uint48 endsAt;
        bool active;
        address settler;
        address token;
    }

    // --- views ---
    function campaignOf(bytes32 id) external view returns (Campaign memory);
    function remaining(bytes32 id) external view returns (uint256);
    function isOracleSigner(address signer) external view returns (bool);
    function guardian() external view returns (address);

    // --- enforcement (postOp) ---
    /// @notice Strict decrement: reverts on over-budget / inactive / expired / wrong-strategy / paused.
    function consume(bytes32 id, uint256 feeWei) external;

    /// @notice postOp-safe decrement: charges min(feeWei, remaining), auto-deactivates on exhaustion,
    ///         and returns 0 (never reverts) when inactive/expired/over-budget/paused so a postOp can
    ///         never be forced into PostOpReverted. Only the bound strategy.
    function consumeUpTo(bytes32 id, uint256 feeWei) external returns (uint256 charged);

    // --- campaign lifecycle (owner = timelock unless noted) ---
    /// @notice Create a NEW campaign. Reverts if the id already exists — budgets cannot be silently
    ///         raised by re-setting; raises go through `raiseBudget` (timelocked).
    function setCampaign(bytes32 id, address strategy, uint128 budgetWei, uint48 endsAt) external;
    /// @notice OWNER (timelock) only: raise an existing campaign's budget. Monotonic up.
    function raiseBudget(bytes32 id, uint128 newBudgetWei) external;
    /// @notice GUARDIAN only: lower an existing campaign's budget. Down only, never below spent.
    function lowerBudget(bytes32 id, uint128 newBudgetWei) external;
    /// @notice OWNER (timelock) only: extend a campaign's expiry (or remove it). Never shortens.
    function extendCampaign(bytes32 id, uint48 newEndsAt) external;
    /// @notice GUARDIAN or OWNER: instant kill of a single campaign.
    function deactivate(bytes32 id) external;
    /// @notice OWNER only: re-activate a campaign (deliberate).
    function reactivate(bytes32 id) external;

    // --- value ceiling (B2): parallel surface for stablecoin/x402 value, in token native units ---
    function valueCampaignOf(bytes32 id) external view returns (ValueCampaign memory);
    function valueRemaining(bytes32 id) external view returns (uint256);
    /// @notice STRICT decrement of a value campaign: reverts on over-budget / inactive / expired /
    ///         wrong-settler / paused. The revert IS the enforcement (blocks the settlement). Only the
    ///         bound settler. Aggregate `valueSpent` across N untrusted callers can never exceed valueBudget.
    function consumeValue(bytes32 id, uint256 amount) external;
    /// @notice Create a NEW value campaign (creation-only). `settler` consumes it; `token` is its unit.
    function setValueCampaign(bytes32 id, address settler, address token, uint128 valueBudget, uint48 endsAt) external;
    /// @notice OWNER (timelock) only: raise a value budget. Monotonic up.
    function raiseValueBudget(bytes32 id, uint128 newValueBudget) external;
    /// @notice GUARDIAN only: lower a value budget. Down only, never below valueSpent.
    function lowerValueBudget(bytes32 id, uint128 newValueBudget) external;
    /// @notice GUARDIAN or OWNER: instant kill of a single value campaign.
    function deactivateValue(bytes32 id) external;
    /// @notice OWNER only: re-activate a value campaign (deliberate).
    function reactivateValue(bytes32 id) external;

    // --- registries (owner = timelock) ---
    function setOracleSigner(address signer, bool allowed) external;
    function setStrategy(address strategy, bool allowed) external;
    function setGuardian(address newGuardian) external;

    // --- global safety ---
    /// @notice GUARDIAN or OWNER: instant fail-closed pause (consume reverts, consumeUpTo returns 0).
    function pause() external;
    /// @notice OWNER only: lift the pause (deliberate).
    function unpause() external;

    event Consumed(bytes32 indexed id, address indexed strategy, uint256 feeWei, uint256 remaining);
    event CampaignSet(bytes32 indexed id, address indexed strategy, uint128 budgetWei, uint48 endsAt);
    event BudgetRaised(bytes32 indexed id, uint128 newBudgetWei);
    event BudgetLowered(bytes32 indexed id, uint128 newBudgetWei);
    event CampaignExtended(bytes32 indexed id, uint48 newEndsAt);
    event OracleSignerSet(address indexed signer, bool allowed);
    event StrategySet(address indexed strategy, bool allowed);
    event ActiveSet(bytes32 indexed id, bool active);
    event GuardianSet(address indexed newGuardian);

    // value-ceiling (B2) events
    event ValueCampaignSet(
        bytes32 indexed id, address indexed settler, address token, uint128 valueBudget, uint48 endsAt
    );
    event ValueConsumed(bytes32 indexed id, address indexed settler, uint256 amount, uint256 remaining);
    event ValueBudgetRaised(bytes32 indexed id, uint128 newValueBudget);
    event ValueBudgetLowered(bytes32 indexed id, uint128 newValueBudget);
    event ValueActiveSet(bytes32 indexed id, bool active);
}
