# Welcome to the GasX Protocol Documentation

This documentation provides a comprehensive overview of the GasX Protocol, from high-level architectural concepts to detailed smart contract references and deployment guides.

GasX is a professional suite of ERC-4337 Paymasters designed to eliminate gas fee friction for any dApp.

---
## 🚀 Getting Started

If you are a developer looking to integrate or contribute to the GasX protocol, these documents are the best place to start.

| Guide | Description |
| :--- | :--- |
| **[Architecture Overview](./overview/01_architecture.md)** | Start here for a high-level understanding of the entire smart contract system. |
| **[Deployment Guide](./guides/01_deployment.md)** | Follow these step-by-step instructions to deploy the protocol on any network. |
| **[Project Roadmap](./overview/02_roadmap.md)** | Explore the long-term vision and planned features for the GasX suite. |

---
## 📚 Table of Contents

### 1. Overview
- **[Architecture](./overview/01_architecture.md):** A deep dive into the smart contract system, its components, and design principles.
- **[Roadmap](./overview/2_roadmap.md):** The long-term vision, including planned features like new paymaster strategies.

### 2. Developer Guides
- **[Deployment Guide](./guides/01_deployment.md):** Step-by-step instructions for deploying all protocol contracts.
- **[Quick Start](./guides/02_quick-start.md):** A guide on setting up the local development environment and running tests.
- **[Environment-Specific Behavior](./guides/03_environments.md):** Explains how the protocol behaves differently in `Dev`, `Testnet`, and `Production`.
- **[Environment Implementation Details](./guides/04_environment_implementation.md):** A technical reference with code snippets on how environment handling is implemented.

### 3. Smart Contract Reference

#### Core Contracts
- **[`GasXWhitelistPaymaster`](./contracts/01_GasXWhitelistPaymaster.md):** Technical reference for the pure gas sponsorship paymaster.
- **[`GasXERC20FeePaymaster`](./contracts/02_GasXERC20FeePaymaster.md):** Technical reference for the paymaster that allows users to pay fees in ERC20 tokens.
- **[`GasXConfig`](./contracts/03_GasXConfig.md):** Technical reference for the protocol's updatable configuration contract.
- **[`GasXSubscriptions`](./contracts/09_GasXSubscriptions.md):** Technical reference for the subscription and credit payment system.

#### Oracle Infrastructure
- **[`MultiOracleAggregator`](./contracts/04_MultiOracleAggregator.md):** Technical reference for the on-chain price oracle aggregation system.
- **[`AggregatorFactory`](./contracts/05_AggregatorFactory.md):** Technical reference for the factory that deploys oracle aggregators.
- **[`DIAOracleAdapter`](./contracts/06_DIAOracleAdapter.md):** Technical reference for the DIA Oracle V2 adapter.
- **[`EulerOracleAdapter`](./contracts/07_EulerOracleAdapter.md):** Technical reference for the Euler Protocol oracle adapter.
- **[`DIAAdapterFactory`](./contracts/08_DIAAdapterFactory.md):** Technical reference for the DIA adapter factory.

### 4. Standards & Specifications
- **[Sponsor-Set Aggregate Spend Ceilings (ERC draft)](./eip-draft-aggregate-spend-ceiling.md):** A denomination-agnostic interface for an on-chain budget shared by N untrusted accounts, with raise/lower authority split by risk direction. `GasXPolicyManager` is the reference implementation.


---
## 🤝 Contributing & Security

- **[Contributing Guide](../CONTRIBUTING.md):** Learn about our development process and coding conventions.
- **[Security Policy](../SECURITY.md):** View our security policy and learn how to report vulnerabilities.
