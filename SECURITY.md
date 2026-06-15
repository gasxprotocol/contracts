# Security Policy — GasX Protocol

GasX takes the security of its smart contracts and infrastructure seriously. This policy covers the public
`gasxprotocol/contracts` repository.

---
## 🛡️ Reporting a vulnerability

**Please DO NOT open a public GitHub issue for security reports.**

Email a detailed report privately to **[edsphinx@gmail.com](mailto:edsphinx@gmail.com)**. Include:
- a description of the vulnerability,
- the contract(s) and network(s) affected,
- steps to reproduce,
- the potential impact.

We aim to acknowledge within 48 hours and will coordinate disclosure with you. A bug-bounty program is planned.

---
## Security posture

GasX is an ERC-4337 paymaster protocol on **EntryPoint v0.9** (canonical
`0x433709009B8330FDa32311DF1C2AFA402eD8D009`; v0.8 has a disclosed griefing issue and is not used).

### Design-level controls
- **On-chain budget enforcement.** `GasXPolicyManager` holds per-campaign budgets that strategies decrement in
  `postOp` (`consumeUpTo`, non-reverting, auto-deactivating). This closes the paymaster-drain class: a campaign
  cannot be spent past its funded limit, and a registered strategy cannot spend a campaign it does not own
  (campaign↔strategy binding).
- **Bundler-safe validation (ERC-7562).** `GasXPaymasterBase.validatePaymasterUserOp` reads **only** the signed
  approval data + the paymaster's own storage (an own-storage trusted-signer mirror) — no cross-contract reads.
  Signature failure and the time window are returned as `validationData`, not reverted.
- **Non-circular signed-approval binding.** The approval binds to the EntryPoint userOpHash over the
  signature-excluded `paymasterAndData`; replay across ops/deploys fails closed. No legacy 52-byte bypass.
- **postOp safety.** Budget consume runs inside `try/catch`; the ERC-20 strategy charges in `postOp` with an
  oracle deviation clamp, balance-delta accounting (fee-on-transfer safe), and CEI + `nonReentrant`.
- Built on battle-tested OpenZeppelin (`ECDSA`, `EIP712`, `Ownable2Step`, `UUPS`, `Pausable`) pinned as
  immutable `lib/` submodules (no npm for contract deps).

### Testing & review
- **154 tests** (151 unit/fuzz + 3 live-fork against the real v0.9 EntryPoint on Arbitrum Sepolia).
- **Internal multi-agent security audit** (adversarial, multi-dimension) — must-fix findings applied + hardened.
- **Slither** runs in CI.
- **External audit:** planned before any mainnet deployment with user funds at scale (e.g. via the Arbitrum
  Audit Program). **Not yet performed** — treat the current code as testnet-stage.

Live, exploitable findings are tracked privately until fixed and disclosed here.
