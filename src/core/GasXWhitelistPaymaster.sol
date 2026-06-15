// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation, UserOperationLib } from "@account-abstraction/contracts/core/UserOperationLib.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { GasXPaymasterBase } from "./GasXPaymasterBase.sol";

/**
 * @title  GasXWhitelistPaymaster
 * @author GasX
 * @notice Full gas sponsorship for whitelisted function selectors, built on `GasXPaymasterBase`: the base
 *         verifies the EIP-712 `SignedApproval` (signer/expiry/maxFee/binding, ERC-7562-safe) and decrements
 *         the on-chain campaign budget in postOp; this strategy layers a selector whitelist + a per-op gas
 *         ceiling on top. The legacy EIP-191 oracle path, `isDevMode` dev-bypass and `GasXConfig`/`treasury`/
 *         `Environment` wiring are REMOVED — the signed-approval flow supersedes them (no 52-byte bypass).
 * @dev    `strategyId = keccak256("gasx.whitelist")`. Not upgradeable (a deposit-holding proxy is a drain surface).
 */
contract GasXWhitelistPaymaster is GasXPaymasterBase, Pausable {
    using UserOperationLib for PackedUserOperation;

    struct Limits {
        uint256 maxGas;
        uint256 maxUsd; // reserved for future USD-based ceilings (not enforced)
    }

    Limits public limits;
    mapping(bytes4 => bool) public allowedSelectors;

    event LimitsUpdated(uint256 maxGas, uint256 maxUsd);
    event SelectorUpdated(bytes4 indexed selector, bool allowed);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    constructor(IEntryPoint _entryPoint, address _policyManager, string memory name, string memory version)
        GasXPaymasterBase(_entryPoint, _policyManager, name, version)
    { }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("gasx.whitelist");
    }

    function supportsCampaign(bytes32) external pure override returns (bool) {
        return true;
    }

    /// @dev Layers the selector whitelist + per-op gas ceiling ON TOP of the base's signed-approval
    ///      verification. Not `view` (the base recomputes the binding hash via the EntryPoint). The
    ///      selector/gas guards run BEFORE `super`, so a disallowed/over-limit op is rejected up front.
    function _validatePaymasterUserOp(PackedUserOperation calldata op, bytes32 opHash, uint256 maxCost)
        internal
        override
        whenNotPaused
        returns (bytes memory context, uint256 validationData)
    {
        require(allowedSelectors[_firstSelector(op.callData)], "GasX: Disallowed function");
        require(op.unpackCallGasLimit() <= limits.maxGas, "GasX: Gas limit exceeded");
        return super._validatePaymasterUserOp(op, opHash, maxCost);
    }

    function setLimit(uint256 gas, uint256 usd) external onlyOwner {
        limits = Limits(gas, usd);
        emit LimitsUpdated(gas, usd);
    }

    function setSelector(bytes4 sel, bool allowed) external onlyOwner {
        allowedSelectors[sel] = allowed;
        emit SelectorUpdated(sel, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover ETH sent directly to this contract (NOT the EntryPoint deposit — use `withdrawTo`).
    function emergencyWithdrawEth(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "GasX: Invalid recipient");
        uint256 toWithdraw = amount == 0 ? address(this).balance : amount;
        require(toWithdraw <= address(this).balance, "GasX: Insufficient balance");
        (bool ok,) = to.call{ value: toWithdraw }("");
        require(ok, "GasX: ETH transfer failed");
        emit EmergencyWithdraw(to, toWithdraw);
    }

    function _firstSelector(bytes calldata cd) private pure returns (bytes4 sel) {
        assembly {
            sel := calldataload(cd.offset)
        }
    }

    receive() external payable { }
}
