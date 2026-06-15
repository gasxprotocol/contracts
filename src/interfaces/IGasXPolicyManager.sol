// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IGasXPolicyManager
 * @author GasX
 * @notice On-chain budget truth for GasX campaigns. The campaign's bound strategy decrements budget
 *         in postOp via `consumeUpTo` (non-reverting) / `consume` (strict); validation never reads
 *         this contract (ERC-7562). The oracle-signer registry is the k-of-n authority whose EIP-712
 *         approvals the paymaster trusts. Each campaign is bound to exactly one strategy so a
 *         registered strategy can never spend a campaign it does not own.
 */
interface IGasXPolicyManager {
    struct Campaign {
        uint128 budgetWei;
        uint128 spentWei;
        uint48 endsAt;
        bool active;
        address strategy; // the only strategy allowed to consume this campaign
    }

    function campaignOf(bytes32 id) external view returns (Campaign memory);
    function remaining(bytes32 id) external view returns (uint256);
    function isOracleSigner(address signer) external view returns (bool);

    /// @notice Strict decrement: reverts on over-budget / inactive / expired / wrong-strategy.
    function consume(bytes32 id, uint256 feeWei) external;

    /// @notice postOp-safe decrement: charges min(feeWei, remaining), auto-deactivates on exhaustion,
    ///         and returns 0 (never reverts) when inactive/expired/over-budget so a postOp can never be
    ///         forced into PostOpReverted (paymaster pays gas with no accounting). Only the bound strategy.
    function consumeUpTo(bytes32 id, uint256 feeWei) external returns (uint256 charged);

    function setCampaign(bytes32 id, address strategy, uint128 budgetWei, uint48 endsAt) external;
    function setActive(bytes32 id, bool active) external;
    function setOracleSigner(address signer, bool allowed) external;
    function setStrategy(address strategy, bool allowed) external;

    event Consumed(bytes32 indexed id, address indexed strategy, uint256 feeWei, uint256 remaining);
    event CampaignSet(bytes32 indexed id, address indexed strategy, uint128 budgetWei, uint48 endsAt);
    event OracleSignerSet(address indexed signer, bool allowed);
    event StrategySet(address indexed strategy, bool allowed);
    event ActiveSet(bytes32 indexed id, bool active);
}
