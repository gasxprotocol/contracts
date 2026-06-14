// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { SimpleAccountFactory } from "@account-abstraction/contracts/accounts/SimpleAccountFactory.sol";
import { GasXWhitelistPaymaster } from "../../contracts/core/GasXWhitelistPaymaster.sol";

/**
 * @title GasXWhitelistPaymaster fork integration test (Tier A of the local rig)
 * @notice Proves a sponsored UserOperation succeeds end-to-end against the LIVE,
 *         on-chain canonical EntryPoint v0.9 on a forked Arbitrum Sepolia — using the
 *         CURRENT (v0.8-compiled) GasX paymaster + stock SimpleAccountFactory, simply
 *         pointed at the v0.9 EntryPoint address. This validates the core D5 hypothesis:
 *         v0.9 is ABI-compatible, so the "migration" is an EntryPoint-address change,
 *         not a library swap.
 *
 *         It also independently re-confirms the launch blockers the probe found:
 *         the paymaster gates on the OUTER `execute()` selector (0xb61d27f6), and the
 *         stock SimpleAccount recovers the signature RAW over the userOpHash (so a raw
 *         `vm.sign` is the correct scheme — the frontend's personal_sign is the AA24 bug).
 *
 *         No bundler is involved (handleOps is called directly from an EOA), so this is
 *         deterministic and free — the inner loop. Tier B (anvil fork + Alto + frontend)
 *         exercises the HTTP path; the real Pimlico-on-Sepolia probe is the final gate.
 *
 * Run: forge test --fork-url https://sepolia-rollup.arbitrum.io/rpc \
 *        --match-contract GasXWhitelistPaymasterForkTest -vvv
 *      (or any Arbitrum Sepolia / One / Base RPC where the v0.9 EntryPoint is deployed)
 */
contract GasXWhitelistPaymasterForkTest is Test {
    // Canonical ERC-4337 EntryPoint v0.9 — same address on Arb Sepolia/One, Base, Base Sepolia.
    address internal constant ENTRYPOINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    // SimpleAccount.execute(address,uint256,bytes) — the OUTER selector the paymaster validates.
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;

    IEntryPoint internal entryPoint = IEntryPoint(ENTRYPOINT_V09);
    SimpleAccountFactory internal factory;
    GasXWhitelistPaymaster internal paymaster;
    PingTarget internal target;

    uint256 internal constant OWNER_PK = 0xA11CE; // smart-account owner EOA key
    address internal constant BUNDLER = address(0xB0B); // EOA that submits handleOps (v0.9 requires a top-level EOA)
    address internal owner; // = vm.addr(OWNER_PK), set in setUp

    function setUp() public {
        // Run against a fork: `forge test --fork-url <arbitrum_sepolia_rpc> --match-contract GasXWhitelistPaymasterForkTest`.
        // The whole run executes on the fork, so the live v0.9 EntryPoint is already present here.
        assertGt(ENTRYPOINT_V09.code.length, 0, "no v0.9 EntryPoint: run with --fork-url <arbitrum_sepolia_rpc>");

        owner = vm.addr(OWNER_PK);
        target = new PingTarget();

        // Deploy the GasX stack pointing at the on-chain v0.9 EntryPoint.
        // config/treasury are non-zero but never read on the SIMPLE-MODE success path.
        factory = new SimpleAccountFactory(entryPoint);
        paymaster = new GasXWhitelistPaymaster(
            entryPoint,
            address(0xC0FFEE),
            address(0xDEAD),
            GasXWhitelistPaymaster.Environment.Testnet
        );
        // The fresh deploy ships the CORRECT selector layer (fixes the AA33 the probe found):
        // whitelist the OUTER execute() selector, not the inner DeFi selector.
        paymaster.setLimit(10_000_000, 0);
        paymaster.setSelector(EXECUTE_SELECTOR, true);

        // Fund the paymaster's EntryPoint deposit (no stake needed: handleOps direct, no bundler rules).
        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{ value: 2 ether }(address(paymaster));
    }

    function test_sponsoredUserOp_succeeds_against_v09() public {
        uint256 salt = 0;
        address sender = factory.getAddress(owner, salt);

        // First-use: deploy the smart account via factory initCode within the UserOp.
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSignature("createAccount(address,uint256)", owner, salt));

        // Outer call: SimpleAccount.execute(target, 0, ping()). The paymaster sees execute()'s selector.
        bytes memory callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(target), uint256(0), abi.encodeWithSignature("ping()")
        );

        PackedUserOperation memory op = PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: initCode,
            callData: callData,
            // accountGasLimits = verificationGasLimit (high 128) | callGasLimit (low 128)
            accountGasLimits: bytes32((uint256(1_000_000) << 128) | uint256(300_000)),
            preVerificationGas: 100_000,
            // gasFees = maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128)
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            // SIMPLE MODE: paymaster(20) | verificationGas(16) | postOpGas(16) = 52 bytes, no oracle data.
            paymasterAndData: abi.encodePacked(address(paymaster), uint128(300_000), uint128(150_000)),
            signature: ""
        });

        // Stock SimpleAccount recovers RAW over the userOpHash → sign the raw digest, no EIP-191 prefix.
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, userOpHash);
        op.signature = abi.encodePacked(r, s, v);

        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        // v0.9 EntryPoint requires tx.origin == msg.sender && msg.sender.code.length == 0.
        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, payable(BUNDLER));

        assertTrue(target.pinged(), "inner call (ping) did not execute");
        assertGt(sender.code.length, 0, "smart account was not deployed via initCode");
        assertLt(entryPoint.balanceOf(address(paymaster)), depositBefore, "paymaster deposit did not decrease (no gas paid)");
    }
}

/// @dev Minimal target whose `ping()` proves the sponsored call reached execution.
contract PingTarget {
    bool public pinged;

    function ping() external {
        pinged = true;
    }
}
