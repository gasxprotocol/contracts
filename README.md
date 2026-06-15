# GasX — Modular ERC-4337 Paymaster Protocol

**GasX makes gasless UX a reusable building block.** A modular ("LEGO") ERC-4337 paymaster suite on a shared
base: swappable sponsorship strategies, an off-chain EIP-712 signed-policy bridge, and a minimal on-chain
budget manager that enforces per-campaign spend limits — closing the classic paymaster-drain risk class.

[![CI](https://github.com/gasxprotocol/contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/gasxprotocol/contracts/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-success)](./LICENCE)

> **Status (2026-06):** A1 — the modular signed-policy paymaster — is **built, internally security-audited, and
> proven end-to-end on a live Arbitrum Sepolia v0.9 EntryPoint fork**. **Testnet-first**; not yet on mainnet.
> Foundry-native; dependencies are pinned `lib/` git submodules (no npm for contracts).

---

## Why GasX

On-chain adoption stalls when a new user must first acquire a native gas token before doing anything. GasX
removes that friction two ways, on one swappable base:

- **Full sponsorship** (`GasXWhitelistPaymaster`) — the protocol pays 100% of gas for pre-approved actions
  (e.g. onboarding, first mint), gated by a function-selector whitelist + per-op gas ceiling.
- **Pay gas in an ERC-20** (`GasXERC20FeePaymaster`) — users pay their fee in a token like USDC; the paymaster
  fronts ETH gas and charges the token fee in `postOp`, oracle-clamped and fee-on-transfer-safe.

The differentiator is **on-chain policy**: a `GasXPolicyManager` holds per-campaign budgets that strategies
decrement in `postOp`, so sponsorship can't be drained past its funded limit.

## Architecture (Approach C — hybrid)

| Piece | Role |
|---|---|
| `GasXPolicyLib` | EIP-712 `SignedApproval` struct + `recover`/`tryRecover` |
| `GasXPaymasterBase` | shared validation — verifies the signed approval reading **only signed data + own storage** (ERC-7562 / bundler-safe), returns packed `validationData`; `postOp` decrements the campaign budget |
| `GasXPolicyManager` | on-chain per-campaign budget/spent/active, **strategy-bound**, oracle-signer registry (UUPS + Ownable2Step) |
| `IGasXPaymasterStrategy` / `IGasXPolicyManager` | the swap planes + per-interface conformance suites |
| `GasXWhitelistPaymaster`, `GasXERC20FeePaymaster` | concrete strategies on the base |
| off-chain bridge (private) | ERC-7677 orchestrator (`pm_getPaymasterData`) + EIP-712 signer + account adapter that produce the approvals the base verifies |

**Binding:** the approval's `userOpHash` is derived on-chain as the EntryPoint userOpHash over the
signature-excluded `paymasterAndData` (canonical verifying-paymaster scheme) — no cross-deploy/op replay.
**EntryPoint:** v0.9 canonical `0x433709009B8330FDa32311DF1C2AFA402eD8D009`.

## Tests & security

- **154 tests green:** 151 unit/fuzz + **3 live-fork tests** against the real v0.9 EntryPoint on Arbitrum
  Sepolia (a sponsored `SimpleAccount` op via `handleOps` decrements the on-chain budget; a no-approval op
  reverts; an exhausted budget caps + auto-deactivates).
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
