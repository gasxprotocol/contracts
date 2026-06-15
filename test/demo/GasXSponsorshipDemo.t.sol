// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { SimpleAccountFactory } from "@account-abstraction/contracts/accounts/SimpleAccountFactory.sol";
import { GasXWhitelistPaymaster } from "../../src/core/GasXWhitelistPaymaster.sol";
import { GasXPolicyManager } from "../../src/core/GasXPolicyManager.sol";
import { GasXPolicyLib } from "../../src/libraries/GasXPolicyLib.sol";

contract DemoTarget {
    bool public pinged;

    function ping() external {
        pinged = true;
    }
}

/**
 * @title GasX sponsorship showcase (live Arbitrum Sepolia fork)
 * @notice A readable, single-flow demo of the A1 paymaster: an EIP-712 SignedApproval sponsors a real UserOp via
 *         a SimpleAccount on the canonical v0.9 EntryPoint, the inner call executes, and postOp decrements the
 *         on-chain campaign budget by actualGasCost — the user spends ZERO gas. Run with -vv to read the log:
 *           forge test --match-contract GasXSponsorshipDemo -vv
 * @dev Self-forks Arbitrum Sepolia (the proven live chain). Set ARBITRUM_SEPOLIA_RPC_URL to override the RPC.
 */
contract GasXSponsorshipDemo is Test {
    address internal constant ENTRYPOINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6; // SimpleAccount.execute(address,uint256,bytes)

    IEntryPoint internal entryPoint = IEntryPoint(ENTRYPOINT_V09);
    SimpleAccountFactory internal factory;
    GasXWhitelistPaymaster internal paymaster;
    GasXPolicyManager internal policy;
    DemoTarget internal target;

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant SIGNER_PK = 0x0AC1E5;
    address internal constant BUNDLER = address(0xB0B);
    address internal owner;
    address internal signer;
    bytes32 internal constant C = keccak256("campaign.demo");
    uint128 internal constant BUDGET = 2 ether;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", vm.rpcUrl("arbitrum_sepolia"));
        vm.createSelectFork(rpc);
        assertGt(ENTRYPOINT_V09.code.length, 0, "no v0.9 EntryPoint on the fork");
        owner = vm.addr(OWNER_PK);
        signer = vm.addr(SIGNER_PK);
        target = new DemoTarget();

        GasXPolicyManager impl = new GasXPolicyManager();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this))));
        policy = GasXPolicyManager(address(proxy));

        factory = new SimpleAccountFactory(entryPoint);
        paymaster = new GasXWhitelistPaymaster(entryPoint, address(policy), "GasX", "1");
        paymaster.setLimit(10_000_000, 0);
        paymaster.setSelector(EXECUTE_SELECTOR, true);
        paymaster.setTrustedSigner(signer, true);

        policy.setStrategy(address(paymaster), true);
        policy.setOracleSigner(signer, true);
        policy.setCampaign(C, address(paymaster), BUDGET, uint48(block.timestamp + 1 days));

        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{ value: BUDGET }(address(paymaster));
    }

    function _ds() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GasX")),
                keccak256(bytes("1")),
                block.chainid,
                address(paymaster)
            )
        );
    }

    function _buildSignedOp(address sender, bytes memory initCode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: initCode,
            callData: abi.encodeWithSignature(
                "execute(address,uint256,bytes)", address(target), uint256(0), abi.encodeWithSignature("ping()")
            ),
            accountGasLimits: bytes32((uint256(1_500_000) << 128) | uint256(300_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
        bytes memory region = abi.encodePacked(
            address(paymaster),
            uint128(300_000),
            uint128(150_000),
            C,
            sender,
            uint256(1 ether), // maxFeeWei
            uint48(0), // validAfter
            type(uint48).max, // validUntil
            bytes32(0) // eligibilityRef
        );
        op.paymasterAndData = region;
        bytes32 bindingHash = entryPoint.getUserOpHash(op); // over the sig-excluded pad
        GasXPolicyLib.SignedApproval memory a = GasXPolicyLib.SignedApproval({
            campaignId: C,
            sender: sender,
            userOpHash: bindingHash,
            maxFeeWei: 1 ether,
            validAfter: 0,
            validUntil: type(uint48).max,
            eligibilityRef: bytes32(0)
        });
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _ds(), GasXPolicyLib.hash(a)));
        (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(SIGNER_PK, digest);
        op.paymasterAndData = abi.encodePacked(region, abi.encodePacked(ar, as_, av)); // 128B + 65B approval sig

        bytes32 fullHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, fullHash);
        op.signature = abi.encodePacked(r, s, v);
    }

    /// @notice Sponsor one UserOp end-to-end and narrate the budget + deposit deltas as a showcase.
    function test_demo_sponsor_userop_zero_gas_for_user() public {
        uint256 salt = 0;
        address sender = factory.getAddress(owner, salt);
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeWithSignature("createAccount(address,uint256)", owner, salt));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _buildSignedOp(sender, initCode);

        uint256 budgetSpentBefore = policy.campaignOf(C).spentWei;
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));
        uint256 userBalBefore = sender.balance; // counterfactual account, never funded

        console.log("======================= [GasX demo] =======================");
        console.log(" chain id                :", block.chainid, "(Arbitrum Sepolia fork)");
        console.log(" campaign budget         : %s ETH", _eth(BUDGET));
        console.log(" smart account (sender)  :", sender);
        console.log(" user ETH balance        : %s ETH (never funded)", _eth(userBalBefore));
        console.log(" sponsoring one UserOp via the canonical v0.9 EntryPoint...");

        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(ops, payable(BUNDLER));

        uint256 budgetSpent = policy.campaignOf(C).spentWei - budgetSpentBefore;
        uint256 depositDelta = depositBefore - entryPoint.balanceOf(address(paymaster));
        uint256 budgetRemaining = BUDGET - policy.campaignOf(C).spentWei;
        uint256 userBalAfter = sender.balance;

        console.log("-----------------------------------------------------------");
        console.log(" inner call executed     :", target.pinged());
        console.log(
            " [GasX demo] sponsored op: budget %s ETH -> %s ETH, user paid 0 gas", _eth(BUDGET), _eth(budgetRemaining)
        );
        console.log(" campaign budget consumed: %s ETH (actualGasCost)", _eth(budgetSpent));
        console.log(" paymaster deposit delta : %s ETH (paid the bundler)", _eth(depositDelta));
        console.log(" user ETH spent          : %s ETH", _eth(userBalBefore - userBalAfter));
        console.log("===========================================================");

        assertTrue(target.pinged(), "inner call did not execute");
        assertGt(budgetSpent, 0, "campaign budget did not decrement");
        assertGt(depositDelta, 0, "deposit did not decrease");
        assertLe(budgetSpent, depositDelta, "consumed cannot exceed gas charged to the paymaster");
        assertEq(userBalBefore - userBalAfter, 0, "user must pay zero gas");
    }

    /// @dev Render wei as a fixed 4-decimal ETH string for the showcase log, e.g. 1999800000000000000 -> "1.9998".
    function _eth(uint256 weiAmount) internal view returns (string memory) {
        uint256 whole = weiAmount / 1 ether;
        uint256 frac = (weiAmount % 1 ether) / 1e14; // 4 decimal places
        return string.concat(vm.toString(whole), ".", _pad4(frac));
    }

    function _pad4(uint256 frac) internal view returns (string memory) {
        bytes memory b = bytes(vm.toString(frac));
        if (b.length >= 4) return string(b);
        bytes memory zeros = new bytes(4 - b.length);
        for (uint256 i = 0; i < zeros.length; i++) {
            zeros[i] = "0";
        }
        return string.concat(string(zeros), string(b));
    }
}
