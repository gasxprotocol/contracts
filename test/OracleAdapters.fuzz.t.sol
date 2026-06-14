// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/oracles/DIAOracleAdapter.sol";
import "../src/oracles/EulerOracleAdapter.sol";
import "../src/factories/DIAAdapterFactory.sol";
import "../src/oracles/MultiOracleAggregator.sol";
import "../src/mocks/MockDIAOracle.sol";
import "../src/mocks/MockEulerOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title OracleAdapters Foundry Fuzz Tests
 * @notice Property-based fuzz testing for DIAOracleAdapter, EulerOracleAdapter, and DIAAdapterFactory
 * @dev Run with: forge test --match-contract OracleAdaptersFuzzTest -vvv
 */
contract OracleAdaptersFuzzTest is Test {
    MockDIAOracle public diaOracle;
    MockEulerOracle public eulerOracle;
    MultiOracleAggregator public aggregator;

    address public owner = address(this);
    address public constant BASE = address(0x1);
    address public constant QUOTE = address(0x2);

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DIA_PRECISION = 1e8; // DIA uses 8 decimals

    function setUp() public {
        // Deploy mock oracles
        diaOracle = new MockDIAOracle();
        eulerOracle = new MockEulerOracle();

        // Set initial prices
        diaOracle.setValue("ETH/USD", 2000e8, uint128(block.timestamp));
        eulerOracle.setPrice(2000e18);

        // Deploy aggregator for factory tests
        MultiOracleAggregator impl = new MultiOracleAggregator();
        bytes memory initData = abi.encodeCall(MultiOracleAggregator.initialize, (owner, 500));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        aggregator = MultiOracleAggregator(address(proxy));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DIAOracleAdapter FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: DIA price scaling
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAAdapter_PriceScaling(uint128 diaPrice, uint128 amount) public {
        // Bound price to reasonable range (avoid zero)
        uint256 price = bound(diaPrice, 1, type(uint64).max);
        uint256 amt = bound(amount, 1, type(uint64).max);

        diaOracle.setValue("TEST/USD", uint128(price), uint128(block.timestamp));

        DIAOracleAdapter adapter = new DIAOracleAdapter(address(diaOracle), BASE, QUOTE, "TEST/USD");

        // NOTE: getQuote(inAmount, base, quote)
        uint256 quote = adapter.getQuote(amt, BASE, QUOTE);

        // DIA price is 8 decimals, we need 18 decimals
        // quote = amount * price * 1e10 / 1e18 = amount * price / 1e8
        uint256 expected = (amt * price * 1e10) / PRECISION;

        assertEq(quote, expected);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: DIA adapter reverts on zero price
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAAdapter_RevertZeroPrice(uint128 amount) public {
        uint256 amt = bound(amount, 1, type(uint128).max);

        diaOracle.setValue("ZERO/USD", 0, uint128(block.timestamp));

        DIAOracleAdapter adapter = new DIAOracleAdapter(address(diaOracle), BASE, QUOTE, "ZERO/USD");

        vm.expectRevert(abi.encodeWithSelector(DIAOracleAdapter.ZeroPrice.selector));
        adapter.getQuote(amt, BASE, QUOTE);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: DIA adapter reverts on stale price
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAAdapter_RevertStalePrice(uint128 amount, uint32 staleTime) public {
        uint256 amt = bound(amount, 1, type(uint128).max);
        // Stale time > 1 hour, but not more than block.timestamp to avoid underflow
        uint256 maxStale = block.timestamp > 3601 ? block.timestamp - 1 : 3601;
        uint256 staleDelta = bound(staleTime, 3601, maxStale);

        // Set a sufficiently high block.timestamp to avoid underflow
        vm.warp(block.timestamp + 10000);

        uint128 oldTimestamp = uint128(block.timestamp - staleDelta);
        diaOracle.setValue("STALE/USD", 1000e8, oldTimestamp);

        DIAOracleAdapter adapter = new DIAOracleAdapter(address(diaOracle), BASE, QUOTE, "STALE/USD");

        vm.expectRevert(abi.encodeWithSelector(DIAOracleAdapter.StalePrice.selector));
        adapter.getQuote(amt, BASE, QUOTE);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: DIA adapter reverts on invalid pair
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAAdapter_RevertInvalidPair(address wrongBase, address wrongQuote) public {
        vm.assume(wrongBase != BASE || wrongQuote != QUOTE);
        vm.assume(wrongBase != address(0) && wrongQuote != address(0));

        diaOracle.setValue("PAIR/USD", 1000e8, uint128(block.timestamp));

        DIAOracleAdapter adapter = new DIAOracleAdapter(address(diaOracle), BASE, QUOTE, "PAIR/USD");

        vm.expectRevert(abi.encodeWithSelector(DIAOracleAdapter.PairNotSet.selector));
        adapter.getQuote(1e18, wrongBase, wrongQuote);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EulerOracleAdapter FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Euler price scaling
    // ─────────────────────────────────────────────────────────

    function testFuzz_EulerAdapter_PriceScaling(uint128 eulerPrice, uint128 amount) public {
        // Bound to avoid overflow
        uint256 price = bound(eulerPrice, 1, type(uint64).max);
        uint256 amt = bound(amount, 1, type(uint64).max);

        eulerOracle.setPrice(price);

        EulerOracleAdapter adapter = new EulerOracleAdapter(address(eulerOracle), BASE, QUOTE);

        // NOTE: getQuote(inAmount, base, quote)
        uint256 quote = adapter.getQuote(amt, BASE, QUOTE);

        // quote = amount * price / 1e18
        uint256 expected = (amt * price) / PRECISION;

        assertEq(quote, expected);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Euler adapter reverts on zero price
    // ─────────────────────────────────────────────────────────

    function testFuzz_EulerAdapter_RevertZeroPrice(uint128 amount) public {
        uint256 amt = bound(amount, 1, type(uint128).max);

        eulerOracle.setPrice(0);

        EulerOracleAdapter adapter = new EulerOracleAdapter(address(eulerOracle), BASE, QUOTE);

        vm.expectRevert(abi.encodeWithSelector(EulerOracleAdapter.ZeroPrice.selector));
        adapter.getQuote(amt, BASE, QUOTE);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Euler adapter reverts on invalid pair
    // ─────────────────────────────────────────────────────────

    function testFuzz_EulerAdapter_RevertInvalidPair(address wrongBase, address wrongQuote) public {
        vm.assume(wrongBase != BASE || wrongQuote != QUOTE);
        vm.assume(wrongBase != address(0) && wrongQuote != address(0));

        eulerOracle.setPrice(1000e18);

        EulerOracleAdapter adapter = new EulerOracleAdapter(address(eulerOracle), BASE, QUOTE);

        vm.expectRevert(abi.encodeWithSelector(EulerOracleAdapter.InvalidPair.selector));
        adapter.getQuote(1e18, wrongBase, wrongQuote);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Euler adapter deployment validation
    // ─────────────────────────────────────────────────────────

    function testFuzz_EulerAdapter_DeploymentValidation(address _base, address _quote) public {
        if (_base == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(EulerOracleAdapter.ZeroAddress.selector));
            new EulerOracleAdapter(address(eulerOracle), _base, _quote);
            return;
        }

        if (_quote == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(EulerOracleAdapter.ZeroAddress.selector));
            new EulerOracleAdapter(address(eulerOracle), _base, _quote);
            return;
        }

        // Valid deployment
        EulerOracleAdapter adapter = new EulerOracleAdapter(address(eulerOracle), _base, _quote);
        assertEq(adapter.base(), _base);
        assertEq(adapter.quote(), _quote);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DIAAdapterFactory FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Factory deployment validation
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_DeploymentValidation(address agg, address dia) public {
        if (agg == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(DIAAdapterFactory.ZeroAddress.selector));
            new DIAAdapterFactory(agg, dia);
            return;
        }

        if (dia == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(DIAAdapterFactory.ZeroAddress.selector));
            new DIAAdapterFactory(agg, dia);
            return;
        }

        DIAAdapterFactory factory = new DIAAdapterFactory(agg, dia);
        assertEq(factory.aggregator(), agg);
        assertEq(factory.dia(), dia);
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Factory creates adapter and adds to aggregator
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_DeployAdapter(address _base, address _quote, uint8 pairId) public {
        vm.assume(_base != address(0) && _quote != address(0) && _base != _quote);

        // Use fixed pair keys to avoid string encoding issues
        string[5] memory pairKeys = ["ETH/USD", "BTC/USD", "USDC/USD", "DAI/USD", "LINK/USD"];
        string memory pairKey = pairKeys[pairId % 5];

        DIAAdapterFactory factory = new DIAAdapterFactory(address(aggregator), address(diaOracle));

        // Set price in DIA oracle
        diaOracle.setValue(pairKey, 1000e8, uint128(block.timestamp));

        address adapter = factory.deployAdapter(_base, _quote, pairKey);

        // Verify adapter was deployed (factory does NOT add to aggregator - that's separate)
        assertTrue(adapter != address(0));

        // Verify factory stored references correctly
        assertEq(factory.aggregator(), address(aggregator));
        assertEq(factory.dia(), address(diaOracle));
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Factory reverts on zero base
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_RevertZeroBase(address _quote) public {
        vm.assume(_quote != address(0));

        DIAAdapterFactory factory = new DIAAdapterFactory(address(aggregator), address(diaOracle));

        vm.expectRevert(abi.encodeWithSelector(DIAAdapterFactory.ZeroAddress.selector));
        factory.deployAdapter(address(0), _quote, "TEST/USD");
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Factory reverts on zero quote
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_RevertZeroQuote(address _base) public {
        vm.assume(_base != address(0));

        DIAAdapterFactory factory = new DIAAdapterFactory(address(aggregator), address(diaOracle));

        vm.expectRevert(abi.encodeWithSelector(DIAAdapterFactory.ZeroAddress.selector));
        factory.deployAdapter(_base, address(0), "TEST/USD");
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Factory reverts on empty key
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_RevertEmptyKey(address _base, address _quote) public {
        vm.assume(_base != address(0) && _quote != address(0));

        DIAAdapterFactory factory = new DIAAdapterFactory(address(aggregator), address(diaOracle));

        vm.expectRevert(abi.encodeWithSelector(DIAAdapterFactory.ZeroKey.selector));
        factory.deployAdapter(_base, _quote, "");
    }

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: Only owner can deploy adapter
    // ─────────────────────────────────────────────────────────

    function testFuzz_DIAFactory_OnlyOwner(address caller) public {
        vm.assume(caller != owner);

        DIAAdapterFactory factory = new DIAAdapterFactory(address(aggregator), address(diaOracle));

        vm.prank(caller);
        vm.expectRevert("not owner");
        factory.deployAdapter(BASE, QUOTE, "TEST/USD");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CROSS-ADAPTER FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    // ─────────────────────────────────────────────────────────
    // FUZZ TEST: DIA and Euler adapters return consistent results
    // ─────────────────────────────────────────────────────────

    function testFuzz_AdaptersConsistentPricing(uint64 price, uint128 amount) public {
        // Use same price for both (accounting for decimal differences)
        uint256 priceVal = bound(price, 1, type(uint32).max);
        uint256 amt = bound(amount, 1, type(uint64).max);

        // DIA uses 8 decimals
        diaOracle.setValue("CONS/USD", uint128(priceVal), uint128(block.timestamp));

        // Euler uses 18 decimals (multiply by 1e10 to match)
        eulerOracle.setPrice(priceVal * 1e10);

        DIAOracleAdapter diaAdapter = new DIAOracleAdapter(address(diaOracle), BASE, QUOTE, "CONS/USD");
        EulerOracleAdapter eulerAdapter = new EulerOracleAdapter(address(eulerOracle), BASE, QUOTE);

        uint256 diaQuote = diaAdapter.getQuote(amt, BASE, QUOTE);
        uint256 eulerQuote = eulerAdapter.getQuote(amt, BASE, QUOTE);

        // Both should return the same quote
        assertEq(diaQuote, eulerQuote, "DIA and Euler quotes should match");
    }
}
