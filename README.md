# GasX — On-Chain Aggregate Spend-Ceiling for Agent Fleets

**GasX caps the total spend of a fleet of untrusted wallets, on-chain.** N independent wallets share ONE
sponsor-set budget that a bound strategy decrements in `postOp` and that fails closed when exhausted. Three
axes no incumbent combines: **sponsor-set + aggregate-across-untrusted-wallets + on-chain-revert.** The engine
is `GasXPolicyManager`; **ERC-4337 gas sponsorship is the proven instance that ships today** (the budget is
gas-denominated), built on a modular ("LEGO") paymaster base with swappable strategies and an off-chain
EIP-712 signed-policy bridge. Stablecoin/x402 value ceilings are the next instance.

[![CI](https://github.com/gasxprotocol/contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/gasxprotocol/contracts/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-success)](./LICENCE)

> **Status (2026-06):** the signed-policy paymaster instance is **built, internally security-audited, and
> proven end-to-end on a live Arbitrum Sepolia v0.9 EntryPoint fork**. Governance hardening (B0) is in: authority
> is split by **risk direction** — a timelock owner raises/extends/upgrades (delayed + public), a separate
> guardian lowers/deactivates/pauses (instant). **Testnet-first**; not yet on mainnet. Foundry-native;
> dependencies are pinned `lib/` git submodules (no npm for contracts).

---

## Why GasX

When a sponsor funds many wallets it does not control — an agent fleet, an onboarding cohort, a campaign's
users — the open question is: what stops their *combined* spend from blowing past the budget? GasX answers it
on-chain. A `GasXPolicyManager` holds a per-campaign budget that the bound strategy decrements in `postOp`, so
N independent wallets draw down ONE budget and the campaign auto-deactivates the moment it is exhausted —
enforcement is a revert, not an off-chain promise.

Gas sponsorship is the proven instance of that ceiling today, in two flavors on one swappable base:

- **Full sponsorship** (`GasXWhitelistPaymaster`) — the protocol pays 100% of gas for pre-approved actions
  (e.g. onboarding, first mint), gated by a function-selector whitelist + per-op gas ceiling.
- **Pay gas in an ERC-20** (`GasXERC20FeePaymaster`) — users pay their fee in a token like USDC; the paymaster
  fronts ETH gas and charges the token fee in `postOp`, oracle-clamped and fee-on-transfer-safe.

The budget is **gas-denominated** today; it bounds gas spend, not arbitrary stablecoin value (that is the
next instance, not yet built).

## Architecture (Approach C — hybrid)

| Piece | Role |
|---|---|
| `GasXPolicyLib` | EIP-712 `SignedApproval` struct + `recover`/`tryRecover` |
| `GasXPaymasterBase` | shared validation — verifies the signed approval reading **only signed data + own storage** (ERC-7562 / bundler-safe), returns packed `validationData`; `postOp` decrements the campaign budget |
| `GasXPolicyManager` | on-chain per-campaign budget/spent/active, **strategy-bound**, oracle-signer registry; authority split by **risk direction** — timelock owner raises/extends/upgrades (delayed + public), guardian lowers/deactivates/pauses (instant); fail-closed `pause` (UUPS + Ownable2Step + Pausable) |
| `IGasXPaymasterStrategy` / `IGasXPolicyManager` | the swap planes + per-interface conformance suites |
| `GasXWhitelistPaymaster`, `GasXERC20FeePaymaster` | concrete strategies on the base |
| off-chain bridge (private) | ERC-7677 orchestrator (`pm_getPaymasterData`) + EIP-712 signer + account adapter that produce the approvals the base verifies |

**Binding:** the approval's `userOpHash` is derived on-chain as the EntryPoint userOpHash over the
signature-excluded `paymasterAndData` (canonical verifying-paymaster scheme) — no cross-deploy/op replay.
**EntryPoint:** v0.9 canonical `0x433709009B8330FDa32311DF1C2AFA402eD8D009`.

## Tests & security

- **173 tests green:** 167 unit/fuzz + **6 live-fork tests** against the real v0.9 EntryPoint on Arbitrum
  Sepolia (a sponsored `SimpleAccount` op via `handleOps` decrements the on-chain budget; a no-approval op
  reverts; an exhausted budget caps + auto-deactivates). The fuzz suite includes the aggregate-cap invariant
  (many ops sharing one campaign can never collectively exceed its budget), the B0 governance proof (the
  guardian lowers/pauses instantly but can never raise or upgrade; raises land only after the timelock delay),
  and the postOp charge-on-revert parity (a reverted op still burns sponsor gas, so it draws down the budget).
- **Internal multi-agent security audit** (must-fix findings applied + hardened) + Slither in CI. See
  [`SECURITY.md`](./SECURITY.md) for disclosure. A formal **external audit is planned** (not yet done).
- Claims here are scoped to what's proven on testnet — no mainnet/production guarantees yet.

## Quick start (Foundry)

```bash
git clone --recurse-submodules git@github.com:gasxprotocol/contracts.git
cd contracts
forge build
forge test                         # full suite (the fork tests self-fork Arbitrum Sepolia)
forge test --no-match-contract Fork  # unit/fuzz only (no RPC)
```

Dependencies are pinned `lib/` submodules (forge-std, OpenZeppelin v5.4.0 + upgradeable,
eth-infinitism/account-abstraction v0.9.0). Set `ARBITRUM_SEPOLIA_RPC_URL` to override the public fork RPC.

## Contributing & security

Open-source under MIT. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) and [`SECURITY.md`](./SECURITY.md). Please
report vulnerabilities privately (do not open a public issue).

## License

MIT — see [`LICENCE`](./LICENCE).

---
_Built in Honduras 🇭🇳_
