// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/factories/AggregatorFactory.sol";
import "../src/oracles/MultiOracleAggregator.sol";
import "../src/mocks/MockOracle.sol";

/**
 * @title AggregatorFactory Foundry Fuzz Tests
 * @notice Property-based fuzz testing for AggregatorFactory
 * @dev Run with: forge test --match-contract AggregatorFactoryFuzzTest -vvv
 */
contract AggregatorFactoryFuzzTest is Test {
    AggregatorFactory public factory;
    MultiOracleAggregator public implementation;
    MockOracle public oracle1;
    MockOracle public oracle2;

    address public owner = address(this);
    uint256 public constant PRECISION = 1e18;

    event AggregatorCreated(address indexed base, address indexed quote, address aggregator);
    event AggregatorRemoved(address indexed base, address indexed quote);

    function setUp() public {
        // Deploy implementation
        implementation = new MultiOracleAggregator();

        // Deploy factory
        factory = new AggregatorFactory(address(implementation));

        // Deploy mock oracles
        oracle1 = new MockOracle(1e18);
        oracle2 = new MockOracle(1.02e18);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Create aggregator with valid params
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_ValidParams(address base, address quote, uint16 deviationBps) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);
        uint256 maxDev = bound(deviationBps, 1, 10000);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        factory.createAggregator(base, quote, oracles, maxDev);

        assertTrue(factory.existsAggregator(base, quote));
        address aggAddr = factory.getAggregator(base, quote);
        assertTrue(aggAddr != address(0));

        // Verify aggregator is configured correctly
        MultiOracleAggregator agg = MultiOracleAggregator(aggAddr);
        assertEq(agg.maxDeviationBps(), maxDev);
        assertEq(agg.oracleCount(base, quote), 1);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot create with zero base
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_RevertZeroBase(address quote) public {
        vm.assume(quote != address(0));

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.ZeroAddress.selector));
        factory.createAggregator(address(0), quote, oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot create with zero quote
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_RevertZeroQuote(address base) public {
        vm.assume(base != address(0));

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.ZeroAddress.selector));
        factory.createAggregator(base, address(0), oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot create with identical tokens
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_RevertIdenticalTokens(address token) public {
        vm.assume(token != address(0));

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.IdenticalTokens.selector));
        factory.createAggregator(token, token, oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot create duplicate aggregator
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_RevertDuplicate(address base, address quote) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        factory.createAggregator(base, quote, oracles, 500);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.AggregatorAlreadyExists.selector));
        factory.createAggregator(base, quote, oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot create reverse pair
    // ─────────────────────────────────────────────────────────

    function testFuzz_CreateAggregator_RevertReversePair(address base, address quote) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        factory.createAggregator(base, quote, oracles, 500);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.ReversePairExists.selector));
        factory.createAggregator(quote, base, oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Remove aggregator works correctly
    // ─────────────────────────────────────────────────────────

    function testFuzz_RemoveAggregator(address base, address quote) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        factory.createAggregator(base, quote, oracles, 500);
        assertTrue(factory.existsAggregator(base, quote));

        factory.removeAggregator(base, quote);
        assertFalse(factory.existsAggregator(base, quote));
        assertEq(factory.getAggregator(base, quote), address(0));
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot remove non-existent aggregator
    // ─────────────────────────────────────────────────────────

    function testFuzz_RemoveAggregator_RevertNotFound(address base, address quote) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);

        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.AggregatorNotFound.selector));
        factory.removeAggregator(base, quote);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Transfer aggregator ownership
    // ─────────────────────────────────────────────────────────

    function testFuzz_TransferAggregatorOwnership(address base, address quote, address newOwner) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);
        vm.assume(newOwner != address(0));

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        factory.createAggregator(base, quote, oracles, 500);

        factory.transferAggregatorOwnership(base, quote, newOwner);

        MultiOracleAggregator agg = MultiOracleAggregator(factory.getAggregator(base, quote));
        assertEq(agg.owner(), newOwner);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Transfer factory ownership
    // ─────────────────────────────────────────────────────────

    function testFuzz_TransferOwnership(address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != owner);

        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), newOwner);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot transfer ownership to zero
    // ─────────────────────────────────────────────────────────

    function testFuzz_TransferOwnership_RevertZero() public {
        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.ZeroAddress.selector));
        factory.transferOwnership(address(0));
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Cannot transfer ownership to same owner
    // ─────────────────────────────────────────────────────────

    function testFuzz_TransferOwnership_RevertSameOwner() public {
        vm.expectRevert(abi.encodeWithSelector(AggregatorFactory.SameOwner.selector));
        factory.transferOwnership(owner);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Only owner can create aggregator
    // ─────────────────────────────────────────────────────────

    function testFuzz_OnlyOwnerCanCreate(address caller) public {
        vm.assume(caller != owner);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1);

        vm.prank(caller);
        vm.expectRevert("not owner");
        factory.createAggregator(address(1), address(2), oracles, 500);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Quote via factory works
    // ─────────────────────────────────────────────────────────

    function testFuzz_QuoteViaFactory(address base, address quote, uint128 amount) public {
        vm.assume(base != address(0) && quote != address(0) && base != quote);
        uint256 amt = bound(amount, 1, type(uint128).max);

        address[] memory oracles = new address[](1);
        oracles[0] = address(oracle1); // Price = 1e18

        factory.createAggregator(base, quote, oracles, 500);

        uint256 quoteValue = factory.quoteViaFactory(base, quote, amt, false);
        assertEq(quoteValue, amt); // Price is 1:1
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Multiple aggregators independent
    // ─────────────────────────────────────────────────────────

    function testFuzz_MultipleAggregatorsIndependent(
        address base1,
        address quote1,
        address base2,
        address quote2
    ) public {
        vm.assume(base1 != address(0) && quote1 != address(0) && base1 != quote1);
        vm.assume(base2 != address(0) && quote2 != address(0) && base2 != quote2);
        vm.assume(base1 != base2 || quote1 != quote2);
        vm.assume(base1 != quote2 || quote1 != base2); // Not reverse pairs

        address[] memory oracles1 = new address[](1);
        oracles1[0] = address(oracle1);

        address[] memory oracles2 = new address[](1);
        oracles2[0] = address(oracle2);

        factory.createAggregator(base1, quote1, oracles1, 500);
        factory.createAggregator(base2, quote2, oracles2, 500);

        assertTrue(factory.existsAggregator(base1, quote1));
        assertTrue(factory.existsAggregator(base2, quote2));

        address agg1 = factory.getAggregator(base1, quote1);
        address agg2 = factory.getAggregator(base2, quote2);

        assertTrue(agg1 != agg2);
    }
}
