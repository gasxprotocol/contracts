// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IGasXPolicyManager } from "../interfaces/IGasXPolicyManager.sol";

/// @notice Minimal EIP-3009 surface. `receiveWithAuthorization` requires `to == msg.sender`, which is
///         exactly what makes a settlement contract the SOLE, front-run-safe choke-point.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/**
 * @title  GasXSettlementRouter (B3)
 * @author GasX
 * @notice The x402 stablecoin settlement choke-point. A facilitator settles a payment THROUGH this
 *         router instead of calling the token directly. The router:
 *           1. enforces the sponsor's aggregate value ceiling on-chain via STRICT `consumeValue` — it
 *              REVERTS (blocking the whole settlement) if the fleet's combined spend would exceed the
 *              campaign's value budget. The revert IS the enforcement.
 *           2. pulls the funds from the paying agent via EIP-3009 `receiveWithAuthorization`, which the
 *              token enforces with `to == msg.sender == this`, so the router is the ONLY path that can
 *              settle this authorization (front-run-safe; no one can divert it).
 *           3. forwards the received amount to the merchant (balance-delta, fee-on-transfer safe).
 *
 * @dev    The value campaign's `settler` MUST be this router (`setValueCampaign(id, router, token, ...)`)
 *         so `consumeValue` accepts it. Enforcement holds only when the merchant's x402 payment
 *         requirements set `payTo = this router`; a payment routed straight to the merchant via
 *         `transferWithAuthorization` bypasses the cap — that is inherent to EIP-3009, and the reason
 *         GasX must be the `to`. The aggregate ceiling is charged the AUTHORIZED `value` (not the net
 *         received), so a fee-on-transfer token cannot be used to under-count spend.
 */
contract GasXSettlementRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IGasXPolicyManager public immutable policyManager;

    event Settled(
        bytes32 indexed campaignId,
        address indexed token,
        address indexed merchant,
        address from,
        uint256 value,
        uint256 forwarded
    );

    error ZeroAddress();

    constructor(IGasXPolicyManager _policyManager) {
        if (address(_policyManager) == address(0)) revert ZeroAddress();
        policyManager = _policyManager;
    }

    /**
     * @notice Settle one x402 payment under the campaign's aggregate value ceiling.
     * @param campaignId  the value campaign whose budget this draws down (its settler must be this router)
     * @param token       the stablecoin (EIP-3009, e.g. USDC)
     * @param from        the paying agent (authorizer)
     * @param merchant    the real recipient (payTo) the funds are forwarded to
     * @param value       the authorized amount (charged in full to the aggregate ceiling)
     * @param validAfter  EIP-3009 authorization window start
     * @param validBefore EIP-3009 authorization window end
     * @param nonce       EIP-3009 authorization nonce (single-use, token-tracked)
     * @param signature   the agent's EIP-3009 authorization over (from, to=this, value, ...)
     */
    function settle(
        bytes32 campaignId,
        address token,
        address from,
        address merchant,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant {
        if (token == address(0) || merchant == address(0)) revert ZeroAddress();

        // 1. Enforce the aggregate ceiling FIRST. Strict: reverts if over budget / inactive / expired /
        //    paused / wrong-settler, which aborts the settlement before any funds move.
        policyManager.consumeValue(campaignId, value);

        // 2. Pull funds from the agent to THIS router. receiveWithAuthorization enforces to==msg.sender,
        //    so only this router can consume the agent's authorization (the sole, front-run-safe path).
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC3009(token).receiveWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, signature);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBal; // fee-on-transfer safe

        // 3. Forward the received amount to the merchant.
        IERC20(token).safeTransfer(merchant, received);
        emit Settled(campaignId, token, merchant, from, value, received);
    }
}
