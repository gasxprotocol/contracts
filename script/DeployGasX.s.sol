// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IEntryPoint } from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { GasXPolicyManager } from "../src/core/GasXPolicyManager.sol";
import { GasXWhitelistPaymaster } from "../src/core/GasXWhitelistPaymaster.sol";

/**
 * @title  DeployGasX
 * @notice Deploys the post-pivot GasX governance stack so the risk-direction authority split is
 *         provable ON-CHAIN: GasXPolicyManager (UUPS proxy) configured by the deployer then OWNED BY A
 *         TIMELOCK; a TimelockController (delayed/public OWNER) controlled by a GOVERNANCE party; a
 *         DISTINCT guardian (instant lower/deactivate/pause); a bound whitelist-paymaster strategy + a
 *         demo aggregate-cap campaign.
 *
 * @dev    SECURITY (hardened after adversarial review):
 *           - GUARDIAN must be distinct from the deployer (else the owner/guardian split is a no-op).
 *           - GOVERNANCE (timelock proposer+executor) should NOT be the deployer; otherwise one key
 *             holds owner-side power AND can cancel its own handoff. The deployer keeps NO timelock role.
 *           - PAYMASTER_DEPOSIT_WEI must be funded or no op can be sponsored (EntryPoint AA31).
 *           - Reverts if the canonical EntryPoint is not deployed on the target chain.
 *         Set ALLOW_INSECURE_DEMO=1 to relax the distinct-guardian / distinct-governance / funded-deposit
 *         guards for a THROWAWAY local/testnet run (loudly warned). Never use it for anything real.
 *
 *         OWNERSHIP HANDOFF is 2-step + timelocked: after broadcast the DEPLOYER IS STILL THE FULL OWNER
 *         (pendingOwner = timelock) with instant upgrade power until `acceptOwnership()` is executed via
 *         the timelock (ScheduleAcceptOwnership then, after the delay, ExecuteAcceptOwnership, run by a
 *         GOVERNANCE proposer/executor). Verify pm.owner()==timelock before calling the deploy "done".
 *
 *         Env (optional unless noted): GUARDIAN (required for real), GOVERNANCE (required for real),
 *         ORACLE_SIGNER, TIMELOCK_DELAY (s, default 300), DEMO_BUDGET_WEI (default 0.01 ether),
 *         PAYMASTER_DEPOSIT_WEI (required for real), ALLOW_INSECURE_DEMO (0/1).
 *
 *         Simulate:  forge script script/DeployGasX.s.sol:DeployGasX --rpc-url arbitrum_sepolia
 *         Broadcast: forge script script/DeployGasX.s.sol:DeployGasX --rpc-url arbitrum_sepolia \
 *                      --broadcast --private-key $DEPLOYER_PK
 */
contract DeployGasX is Script {
    address internal constant ENTRYPOINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6; // SimpleAccount.execute(address,uint256,bytes)
    bytes32 internal constant DEMO_CAMPAIGN = keccak256("campaign.demo.fleet");

    GasXPolicyManager internal pm;
    address internal pmImpl;
    GasXWhitelistPaymaster internal paymaster;
    TimelockController internal timelock;

    function run() external {
        // require the canonical EntryPoint actually exists on this chain (MUST-FIX #4: fail fast,
        // otherwise the paymaster binds to a dead address and every sponsorship silently bricks).
        require(ENTRYPOINT_V09.code.length > 0, "EntryPoint v0.9 not deployed on this chain");

        bool insecure = vm.envOr("ALLOW_INSECURE_DEMO", uint256(0)) == 1;

        vm.startBroadcast();
        address deployer = msg.sender;
        address guardian = vm.envOr("GUARDIAN", insecure ? deployer : address(0));
        address governance = vm.envOr("GOVERNANCE", insecure ? deployer : address(0));
        address oracleSigner = vm.envOr("ORACLE_SIGNER", deployer);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(300));
        uint128 demoBudget = uint128(vm.envOr("DEMO_BUDGET_WEI", uint256(0.01 ether)));
        uint256 deposit = vm.envOr("PAYMASTER_DEPOSIT_WEI", uint256(0));

        // MUST-FIX #1/#2: the split is meaningless if the guardian or the timelock controller is the
        // deployer. Demand distinct keys unless explicitly running the throwaway insecure demo.
        if (!insecure) {
            require(guardian != address(0) && guardian != deployer, "GUARDIAN must be set and != deployer");
            require(governance != address(0) && governance != deployer, "GOVERNANCE must be set and != deployer");
            require(guardian != governance, "GUARDIAN must differ from GOVERNANCE (owner vs kill split)");
            require(deposit > 0, "PAYMASTER_DEPOSIT_WEI must be > 0 (else sponsorship reverts AA31)");
        }
        if (deposit > 0) require(deployer.balance >= deposit, "deployer balance < PAYMASTER_DEPOSIT_WEI");

        _deploy(deployer, oracleSigner, governance, delay);
        require(guardian != address(timelock), "GUARDIAN must differ from the timelock");
        _configure(guardian, oracleSigner, demoBudget);
        _handoff(deployer);

        if (deposit > 0) IEntryPoint(ENTRYPOINT_V09).depositTo{ value: deposit }(address(paymaster));

        vm.stopBroadcast();
        _log(deployer, guardian, governance, oracleSigner, delay, demoBudget, deposit, insecure);
    }

    function _deploy(address deployer, address oracleSigner, address governance, uint256 delay) internal {
        GasXPolicyManager impl = new GasXPolicyManager();
        pmImpl = address(impl);
        pm = GasXPolicyManager(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(GasXPolicyManager.initialize, (deployer))))
        );

        paymaster = new GasXWhitelistPaymaster(IEntryPoint(ENTRYPOINT_V09), address(pm), "GasX", "1");
        paymaster.setLimit(10_000_000, 0); // per-op execution-gas sanity bound; NOT the spend cap
        paymaster.setSelector(EXECUTE_SELECTOR, true);
        paymaster.setTrustedSigner(oracleSigner, true);

        // GOVERNANCE (not the deployer, in secure mode) is the sole proposer+executor+canceller.
        address[] memory props = new address[](1);
        props[0] = governance;
        address[] memory execs = new address[](1);
        execs[0] = governance;
        timelock = new TimelockController(delay, props, execs, address(0)); // self-administered, no admin
    }

    function _configure(address guardian, address oracleSigner, uint128 demoBudget) internal {
        pm.setStrategy(address(paymaster), true);
        pm.setOracleSigner(oracleSigner, true);
        pm.setGuardian(guardian);
        pm.setCampaign(DEMO_CAMPAIGN, address(paymaster), demoBudget, uint48(block.timestamp + 30 days));
    }

    // Transfer ownership to the timelock (2-step). The accept is scheduled+executed by GOVERNANCE via
    // ScheduleAcceptOwnership/ExecuteAcceptOwnership. If the deployer happens to be a proposer (insecure
    // demo, GOVERNANCE==deployer), schedule it inline as a convenience.
    function _handoff(address deployer) internal {
        pm.transferOwnership(address(timelock));
        if (timelock.hasRole(timelock.PROPOSER_ROLE(), deployer)) {
            timelock.schedule(
                address(pm), 0, abi.encodeWithSignature("acceptOwnership()"), bytes32(0), bytes32(0), timelock.getMinDelay()
            );
        }
    }

    function _log(
        address deployer,
        address guardian,
        address governance,
        address oracleSigner,
        uint256 delay,
        uint128 demoBudget,
        uint256 deposit,
        bool insecure
    ) internal view {
        console2.log("== GasX governance stack deployed ==");
        console2.log("PolicyManager (proxy): %s", address(pm));
        console2.log("PolicyManager impl:    %s", pmImpl);
        console2.log("Strategy (paymaster):  %s", address(paymaster));
        console2.log("TimelockController:    %s", address(timelock));
        console2.log("Governance (timelock): %s", governance);
        console2.log("Guardian:              %s", guardian);
        console2.log("Oracle signer:         %s", oracleSigner);
        console2.log("Timelock delay (s):    %s", delay);
        console2.log("Demo campaign budget:  %s wei", uint256(demoBudget));
        console2.log("Paymaster EP deposit:  %s wei (balance: %s)", deposit, IEntryPoint(ENTRYPOINT_V09).balanceOf(address(paymaster)));
        console2.logBytes32(DEMO_CAMPAIGN);
        console2.log("OWNER NOW: deployer is STILL the full owner (pendingOwner=timelock) with upgrade power");
        console2.log("  until acceptOwnership() runs via the timelock. Finish: Schedule then Execute, then verify owner==timelock.");
        if (insecure) console2.log("!! ALLOW_INSECURE_DEMO: guardian/governance may equal the deployer -- NOT a real authority split.");
        if (oracleSigner == deployer) console2.log("!! WARNING: ORACLE_SIGNER == deployer; use a separate off-chain signer key for anything real.");
        if (deposit == 0) console2.log("!! WARNING: paymaster EntryPoint deposit is 0 -- sponsored ops will revert AA31 until funded.");
    }
}

/**
 * @notice GOVERNANCE step A: schedule the timelocked `acceptOwnership()`. Run by a timelock proposer.
 *         Env: TIMELOCK, POLICY_MANAGER. Then wait TIMELOCK_DELAY and run ExecuteAcceptOwnership.
 */
contract ScheduleAcceptOwnership is Script {
    function run() external {
        TimelockController tl = TimelockController(payable(vm.envAddress("TIMELOCK")));
        address pm = vm.envAddress("POLICY_MANAGER");
        vm.startBroadcast();
        tl.schedule(pm, 0, abi.encodeWithSignature("acceptOwnership()"), bytes32(0), bytes32(0), tl.getMinDelay());
        vm.stopBroadcast();
        console2.log("Scheduled acceptOwnership via timelock; execute after the delay with ExecuteAcceptOwnership.");
    }
}

/**
 * @notice GOVERNANCE step B: after the delay, execute the scheduled `acceptOwnership()` so the timelock
 *         becomes the PolicyManager owner. Run by a timelock executor. Env: TIMELOCK, POLICY_MANAGER.
 */
contract ExecuteAcceptOwnership is Script {
    function run() external {
        TimelockController tl = TimelockController(payable(vm.envAddress("TIMELOCK")));
        address pm = vm.envAddress("POLICY_MANAGER");
        vm.startBroadcast();
        tl.execute(pm, 0, abi.encodeWithSignature("acceptOwnership()"), bytes32(0), bytes32(0));
        vm.stopBroadcast();
        require(GasXPolicyManager(pm).owner() == address(tl), "handoff failed: owner != timelock");
        console2.log("acceptOwnership executed; PolicyManager owner is now the timelock.");
    }
}
