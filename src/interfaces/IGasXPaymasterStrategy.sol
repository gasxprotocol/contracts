// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IGasXPaymasterStrategy
 * @author GasX
 * @notice The GasX-specific surface on top of ERC-4337 `IPaymaster`. `validatePaymasterUserOp`
 *         and `postOp` are inherited via `GasXPaymasterBase`; this is the swap-plane identity.
 */
interface IGasXPaymasterStrategy {
    function strategyId() external view returns (bytes32);
    function policyManager() external view returns (address);
    function entryPoint() external view returns (address);
    function supportsCampaign(bytes32 campaignId) external view returns (bool);

    event GasXSponsored(bytes32 indexed campaignId, address indexed sender, bytes32 userOpHash, uint256 actualFeeWei);
}
