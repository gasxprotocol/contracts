---
eip: <to be assigned>
title: Sponsor-Set Aggregate Spend Ceilings
description: An interface for an on-chain budget shared by many untrusted accounts, with raise/lower authority split by risk direction.
author: GasX (@gasxprotocol)
discussions-to: <URL to be assigned>
status: Draft
type: Standards Track
category: ERC
created: 2026-06-18
requires: 712
---

## Abstract

This EIP specifies a minimal interface for an **aggregate spend ceiling**: an on-chain budget,
identified by a `campaignId`, that is set by a *sponsor* and drawn down by N independent accounts the
sponsor does **not** control. Each draw-down (`consume`) is decremented on-chain and the campaign
**fails closed** — the combined spend of all accounts can never exceed the budget. Authority is split by
**risk direction**: only a delayed/public owner may RAISE a budget, register a campaign, or upgrade the
enforcer; a separate, instant *guardian* may only LOWER, deactivate, or pause. The ceiling is
denomination-agnostic (it counts gas, a stablecoin's native units, or any monotonic quantity).

## Motivation

When a sponsor funds activity for accounts it does not control — an agent fleet, an onboarding cohort,
a campaign's users — the open question is what bounds their **combined** spend. Existing mechanisms do
not answer it:

- **Per-account limits** (per-wallet allowances, per-op gas caps) bound each account in isolation; ten
  accounts at the limit still spend ten times the limit. There is no shared ceiling.
- **Off-chain budgets** (a spending service that stops authorizing at a threshold) are not enforced on
  chain; a compromised or buggy authorizer overspends with no on-chain backstop.
- **Self-set on-chain limits** (an account caps its own spend) do not help a sponsor bound accounts it
  does not trust.

The missing primitive is a **sponsor-set, aggregate, on-chain-enforced** ceiling across untrusted
accounts. This EIP standardizes it so wallets, paymasters, x402 facilitators, and budget tooling can
target one interface, and so the safety property (combined spend ≤ budget) is verifiable on chain.

## Specification

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be
interpreted as described in RFC 2119 and RFC 8174.

### Roles

- **Owner** — the only role that MAY register a campaign, RAISE a budget, extend an expiry, or upgrade
  the enforcer. To make these changes delayed and publicly visible, the owner SHOULD be a timelock
  contract (e.g. a `TimelockController`) controlled by a multisig.
- **Guardian** — a role distinct from the owner that MAY only LOWER a budget, deactivate a campaign, or
  pause the enforcer. The guardian MUST NOT be able to raise, register, unpause, or upgrade. The
  guardian SHOULD be a different key/contract from the owner; if they are the same, the split provides
  no protection.

### Interface

```solidity
interface IAggregateSpendCeiling {
    struct Campaign {
        uint128 budget;   // the aggregate ceiling, in the campaign's denomination
        uint128 spent;    // monotonically increasing; MUST NOT exceed `budget`
        uint48  endsAt;   // expiry (0 = no expiry)
        bool    active;
        address consumer; // the ONLY address allowed to draw this campaign down
    }

    // --- views ---
    function campaignOf(bytes32 id) external view returns (Campaign memory);
    function remaining(bytes32 id) external view returns (uint256);

    // --- enforcement ---
    /// @notice Strict draw-down: MUST revert if `amount` would push `spent` past `budget`, or if the
    ///         campaign is inactive/expired/paused, or if `msg.sender` is not the bound `consumer`.
    ///         The revert IS the enforcement (it aborts the calling operation).
    function consume(bytes32 id, uint256 amount) external;

    /// @notice Non-reverting draw-down for callers that MUST NOT revert (e.g. an ERC-4337 `postOp`):
    ///         charges `min(amount, remaining)`, auto-deactivates on exhaustion, and returns 0 on any
    ///         inactive/expired/paused/over-budget condition. MUST NOT let aggregate `spent` exceed
    ///         `budget`. Returns the amount actually charged.
    function consumeUpTo(bytes32 id, uint256 amount) external returns (uint256 charged);

    // --- lifecycle ---
    /// @notice OWNER only. Creation-only: MUST revert if `id` already exists, so a budget can never be
    ///         silently raised by re-setting.
    function setCampaign(bytes32 id, address consumer, uint128 budget, uint48 endsAt) external;
    /// @notice OWNER only. MUST be monotonic up (revert unless `newBudget` > current).
    function raiseBudget(bytes32 id, uint128 newBudget) external;
    /// @notice GUARDIAN only. MUST be down only and MUST NOT set `budget` below `spent`.
    function lowerBudget(bytes32 id, uint128 newBudget) external;
    /// @notice GUARDIAN or OWNER. Instant deactivate of a single campaign.
    function deactivate(bytes32 id) external;

    // --- events (REQUIRED) ---
    event Consumed(bytes32 indexed id, address indexed consumer, uint256 amount, uint256 remaining);
    event CampaignSet(bytes32 indexed id, address indexed consumer, uint128 budget, uint48 endsAt);
    event BudgetRaised(bytes32 indexed id, uint128 newBudget);
    event BudgetLowered(bytes32 indexed id, uint128 newBudget);
    event ActiveSet(bytes32 indexed id, bool active);
}
```

### Semantics

1. A campaign MUST bind exactly one `consumer`; `consume`/`consumeUpTo` MUST revert/return-0 when
   `msg.sender != consumer`. (A campaign MAY be consumed via a single contract that aggregates many
   untrusted callers, e.g. a paymaster strategy or a settlement router.)
2. `spent` MUST be monotonically non-decreasing and MUST never exceed `budget`. When `spent` reaches
   `budget`, the campaign MUST auto-deactivate.
3. A paused enforcer MUST cause `consume` to revert and `consumeUpTo` to return 0 (global fail-closed).
4. Denomination is campaign-defined and out of band of this interface (gas wei, a token's native
   units, etc.); implementations MUST NOT perform on-chain price conversion as part of enforcement.
5. Implementations MAY add a parallel set of functions for a second denomination (e.g. a value ceiling
   alongside a gas ceiling) provided each obeys (1)–(4) independently.

## Rationale

- **Aggregate, not per-account.** The novel guarantee is a ceiling on *combined* spend across accounts
  the sponsor does not control. A single shared `Campaign.budget`/`spent` is the smallest state that
  expresses it.
- **On-chain revert as enforcement.** Bounding the *recoverable* spend on chain (rather than trusting an
  off-chain authorizer) is what makes the cap a guarantee. Two draw-down modes are specified because
  some callers can revert (`consume`, where the revert aborts the operation) and some MUST NOT
  (`consumeUpTo`, for ERC-4337 `postOp`, which must never force `PostOpReverted`).
- **Risk-direction split.** Raising the ceiling or replacing the enforcer is the *dangerous* direction;
  it is gated to a delayed, public owner. Lowering/killing is the *safe* direction; it is instant via a
  separate guardian. This lets an operator react to abuse immediately without being able to silently or
  instantly expand spend.
- **Creation-only `setCampaign`.** Forbidding re-set closes a silent-raise path; all raises go through
  the monotonic, owner-gated (and SHOULD be timelocked) `raiseBudget`.

## Backwards Compatibility

No backwards compatibility issues; this is a new interface. It composes with ERC-4337 (a paymaster is a
`consumer` calling `consumeUpTo` in `postOp`) and with EIP-3009 settlement flows (a settlement contract
is a `consumer` calling `consume` before forwarding funds). It requires EIP-712 only if signed
authorizations gate who may create campaigns (implementation-defined, out of scope here).

## Reference Implementation

`GasXPolicyManager` (UUPS-upgradeable, `Ownable2Step` + `Pausable`) implements this interface for a gas
denomination (`Campaign`/`consume`/`consumeUpTo`) and, in parallel, a value denomination
(`ValueCampaign`/`consumeValue`). It is deployed on Arbitrum Sepolia testnet with the owner set to a
`TimelockController` and a distinct guardian, and the aggregate-cap property is proven by a fuzz
invariant (`spent` never exceeds `budget` across N draw-downs) and end-to-end fork tests against the
canonical ERC-4337 v0.9 EntryPoint. Source: <https://github.com/gasxprotocol/contracts>. (Testnet,
internally reviewed; no external audit; not on mainnet.)

## Security Considerations

- **Guardian distinctness.** If the guardian equals the owner (or the key that controls the owner/
  timelock), the risk-direction split is void. Implementations and deployments MUST keep them distinct.
- **Consumer is the trust boundary.** The cap bounds what the bound `consumer` can recoup against the
  budget; it does not constrain a `consumer` from spending its own funds. Choose the `consumer`
  carefully (it is effectively trusted to report `amount` truthfully).
- **`consumeUpTo` residual.** Because `consumeUpTo` never reverts, a caller MAY perform an operation
  whose cost is only partially charged once the budget is near exhaustion (the campaign then
  auto-deactivates). The bounded residual is at most one operation; an off-chain authorizer SHOULD stop
  issuing approvals before exhaustion to avoid it.
- **Denomination mismatch.** Counting a gas budget and a value budget MUST use separate state; mixing
  units (e.g. gas wei and 6-dp stablecoin units) in one counter corrupts the invariant.
- **Upgradeability.** If the enforcer is upgradeable, the upgrade authority MUST be the owner (and
  SHOULD be timelocked) so the guardian cannot replace enforcement and an upgrade is delayed and public.

## Copyright

Copyright and related rights waived via [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
