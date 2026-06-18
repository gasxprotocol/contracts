// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { GasXSettlementRouter } from "../src/core/GasXSettlementRouter.sol";

/// @notice Faithful EIP-3009 token: `receiveWithAuthorization` enforces `to == msg.sender` (the property
///         that makes a settlement contract the sole, front-run-safe choke-point) + EIP-712 sig checks.
///         Mirrors Circle USDC's interface so the router test is deterministic without forking/dealing.
contract MockERC3009 {
    string public constant name = "Mock USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Mock USDC")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(to == msg.sender, "ERC3009: caller must be the payee"); // <-- the choke-point property
        require(block.timestamp > validAfter, "ERC3009: not yet valid");
        require(block.timestamp < validBefore, "ERC3009: expired");
        require(!authorizationState[from][nonce], "ERC3009: authorization used");
        bytes32 structHash = keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        require(ECDSA.recover(digest, signature) == from, "ERC3009: invalid signature");
        authorizationState[from][nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

contract GasXSettlementRouterTest is Test {
    GasXPolicyManager internal pm;
    GasXSettlementRouter internal router;
    MockERC3009 internal usdc;
    address internal merchant = makeAddr("merchant");
    bytes32 internal constant VC = keccak256("vc.x402");

    function setUp() public {
        GasXPolicyManager impl = new GasXPolicyManager();
        pm = GasXPolicyManager(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (address(this)))))
        );
        usdc = new MockERC3009();
        router = new GasXSettlementRouter(pm);
        // the value campaign's settler MUST be the router so consumeValue accepts it.
        pm.setValueCampaign(VC, address(router), address(usdc), 10_000_000, uint48(block.timestamp + 1 days)); // 10 USDC
    }

    function _sign(uint256 pk, address from, uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                address(router),
                value,
                uint256(0),
                type(uint256).max,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint256 agentPk, uint256 value, bytes32 nonce) internal {
        address agent = vm.addr(agentPk);
        bytes memory sig = _sign(agentPk, agent, value, nonce);
        router.settle(VC, address(usdc), agent, merchant, value, 0, type(uint256).max, nonce, sig);
    }

    function test_settle_enforces_cap_pulls_and_forwards() public {
        uint256 pk = 0xA1;
        address agent = vm.addr(pk);
        usdc.mint(agent, 5_000_000);

        _settle(pk, 4_000_000, keccak256("n1"));

        assertEq(usdc.balanceOf(merchant), 4_000_000, "merchant received the payment");
        assertEq(usdc.balanceOf(agent), 1_000_000, "agent debited");
        assertEq(pm.valueCampaignOf(VC).valueSpent, 4_000_000, "aggregate ceiling charged the authorized value");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing (forwarded)");
    }

    // THE PROOF: three untrusted agents settle against ONE value budget (10 USDC). The third exceeds it
    // and its settlement REVERTS on-chain — no funds move, aggregate spend never exceeds the ceiling.
    function test_three_agents_one_value_ceiling() public {
        uint256[3] memory pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(vm.addr(pks[i]), 5_000_000);
        }
        _settle(pks[0], 4_000_000, keccak256("a")); // ok: spent 4
        _settle(pks[1], 4_000_000, keccak256("b")); // ok: spent 8, remaining 2

        // agent C tries 4 USDC but only 2 remain -> strict consumeValue reverts -> whole settlement aborts
        address c = vm.addr(pks[2]);
        bytes memory sig = _sign(pks[2], c, 4_000_000, keccak256("c"));
        vm.expectRevert(GasXPolicyManager.ValueBudgetExceeded.selector);
        router.settle(VC, address(usdc), c, merchant, 4_000_000, 0, type(uint256).max, keccak256("c"), sig);

        assertEq(pm.valueCampaignOf(VC).valueSpent, 8_000_000, "aggregate never exceeded the 10 USDC ceiling");
        assertEq(usdc.balanceOf(c), 5_000_000, "rejected agent was NOT debited (no funds moved)");
        assertEq(usdc.balanceOf(merchant), 8_000_000, "merchant got only the two within-budget payments");
    }

    function test_router_is_sole_settlement_path() public {
        // Anyone calling receiveWithAuthorization with to != themselves fails: only the router (as `to`)
        // can consume the authorization. This is the choke-point property GasX relies on.
        uint256 pk = 0xA1;
        address agent = vm.addr(pk);
        usdc.mint(agent, 5_000_000);
        bytes memory sig = _sign(pk, agent, 1_000_000, keccak256("x"));
        vm.expectRevert("ERC3009: caller must be the payee");
        usdc.receiveWithAuthorization(agent, address(router), 1_000_000, 0, type(uint256).max, keccak256("x"), sig);
    }

    function test_settle_reverts_when_campaign_paused() public {
        uint256 pk = 0xA1;
        address agent = vm.addr(pk);
        usdc.mint(agent, 5_000_000);
        pm.pause();
        bytes memory sig = _sign(pk, agent, 1_000_000, keccak256("p"));
        vm.expectRevert(); // consumeValue is whenNotPaused -> EnforcedPause aborts the settlement
        router.settle(VC, address(usdc), agent, merchant, 1_000_000, 0, type(uint256).max, keccak256("p"), sig);
        assertEq(usdc.balanceOf(merchant), 0, "nothing settled while paused");
    }
}
