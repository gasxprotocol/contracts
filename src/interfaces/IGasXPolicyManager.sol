// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IGasXPolicyManager
 * @author GasX
 * @notice On-chain budget truth for GasX campaigns. Strategies decrement budget in postOp via
 *         `consume`; validation never reads this contract (ERC-7562). The oracle-signer registry
 *         is the k-of-n authority whose EIP-712 approvals the paymaster trusts.
 */
interface IGasXPolicyManager {
    struct Campaign {
        uint128 budgetWei;
        uint128 spentWei;
        uint48 endsAt;
        bool active;
    }

    function campaignOf(bytes32 id) external view returns (Campaign memory);
    function remaining(bytes32 id) external view returns (uint256);
    function isOracleSigner(address signer) external view returns (bool);

    /// @notice onlyStrategy; called in postOp; reverts on exhaustion; auto-deactivates when spent==budget.
    function consume(bytes32 id, uint256 feeWei) external;

    function setCampaign(bytes32 id, uint128 budgetWei, uint48 endsAt) external;
    function setActive(bytes32 id, bool active) external;
    function setOracleSigner(address signer, bool allowed) external;

    event Consumed(bytes32 indexed id, address indexed strategy, uint256 feeWei, uint256 remaining);
    event CampaignSet(bytes32 indexed id, uint128 budgetWei, uint48 endsAt);
    event OracleSignerSet(address indexed signer, bool allowed);
    event StrategySet(address indexed strategy, bool allowed);
    event ActiveSet(bytes32 indexed id, bool active);

    function setStrategy(address strategy, bool allowed) external;
}
