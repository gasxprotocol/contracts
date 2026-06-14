// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MultiOracleAggregator } from "../oracles/MultiOracleAggregator.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { EulerOracleAdapter } from "../oracles/EulerOracleAdapter.sol";

/**
 * @title AggregatorFactory
 * @author edsphinx
 * @notice Deploys and manages MultiOracleAggregator contracts per asset pair.
 *         Each (base, quote) pair gets its own aggregator instance.
 * @dev Designed for compatibility with MultiOracleAggregator and oracle adapters conforming to IPriceOracle.
 */
contract AggregatorFactory {
    // ────────────────────────────────────────────────
    // ░░  CUSTOM ERRORS
    // ────────────────────────────────────────────────

    error ZeroAddress();
    error IdenticalTokens();
    error AggregatorAlreadyExists();
    error ReversePairExists();
    error NoOracles();
    error AggregatorNotFound();
    error SameOwner();
    error ZeroImplementation();

    /// @notice Owner address with permissions to create and remove aggregators
    address public owner;

    /// @notice Address of the previously deployed logic contract
    address public immutable aggregatorImplementation;

    /// @notice Mapping from base token ⇒ quote token ⇒ aggregator address
    mapping(address => mapping(address => address)) private _aggregators;

    // ────────────────────────────────────────────────
    // ░░  EVENTS
    // ────────────────────────────────────────────────

    /**
     * @notice Emitted when a new aggregator is deployed
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param aggregator Address of the deployed aggregator
     */
    event AggregatorCreated(address indexed base, address indexed quote, address aggregator);

    /**
     * @notice Emitted when an aggregator is removed
     * @param base Address of the base token
     * @param quote Address of the quote token
     */
    event AggregatorRemoved(address indexed base, address indexed quote);

    /**
     * @notice Emitted when the ownership of an aggregator is transferred to a new address
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param newOwner New owner address
     */
    event AggregatorOwnershipTransferred(address indexed base, address indexed quote, address newOwner);

    /**
     * @notice Emitted when the max deviation for an aggregator is updated
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param maxDeviationBps Maximum allowed deviation between oracles (in basis points)
     */
    event MaxDeviationUpdated(address indexed base, address indexed quote, uint256 maxDeviationBps);

    /**
     * @notice Emitted when the ownership of the contract is transferred to a new address
     * @param previousOwner Previous owner address
     * @param newOwner New owner address
     */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Emitted when an aggregator creation is skipped
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param reason Reason for skipping
     */
    event AggregatorCreationSkipped(address indexed base, address indexed quote, string reason);

    /**
     * @notice Emitted when a quote request is made
     * @param caller Address of the caller
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param inAmount Amount of base token being priced
     * @param method Method used to make the request
     */
    event QuoteRequested(
        address indexed caller,
        address indexed base,
        address indexed quote,
        uint256 inAmount,
        string method
    );

    // ────────────────────────────────────────────────
    // ░░  MODIFIERS
    // ────────────────────────────────────────────────

    /// @dev Restricts function execution to the contract owner
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /**
     * @notice Deploys the factory contract
     * @dev Sets the deployer as the owner
     * @param _implementation Address of the MultiOracleAggregator implementation contract
     */
    constructor(address _implementation) {
        if (_implementation == address(0)) revert ZeroImplementation();
        aggregatorImplementation = _implementation;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**
     * @notice Transfers the ownership of the contract to a new address
     * @param newOwner New owner address
     * @custom:access Only callable by owner
     * @dev Reverts if the new owner is zero or same as current
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner) revert SameOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ────────────────────────────────────────────────
    // ░░  FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Deploys and initializes a MultiOracleAggregator for a given asset pair
     * @param base Address of the base token (e.g., ETH)
     * @param quote Address of the quote token (e.g., USDC)
     * @param oracles List of IPriceOracle-compatible addresses to register
     * @param maxDeviationBps Maximum allowed deviation between oracles (in basis points)
     * @return aggregator Address of the deployed MultiOracleAggregator
     * @custom:access Only callable by owner
     * @dev Reverts if an aggregator already exists for the pair
     * @dev Slither reentrancy warning is a false positive: `new` creates a contract at a
     *      deterministic address and executes synchronously, not a reentrancy vector.
     */
    // slither-disable-next-line reentrancy-no-eth
    function createAggregator(
        address base,
        address quote,
        address[] calldata oracles,
        uint256 maxDeviationBps
    ) external onlyOwner returns (address aggregator) {
        if (base == address(0) || quote == address(0)) revert ZeroAddress();
        if (base == quote) revert IdenticalTokens();
        if (_aggregators[base][quote] != address(0)) {
            emit AggregatorCreationSkipped(base, quote, "already exists");
            revert AggregatorAlreadyExists();
        }
        if (_aggregators[quote][base] != address(0)) {
            emit AggregatorCreationSkipped(base, quote, "reverse pair exists");
            revert ReversePairExists();
        }
        if (oracles.length == 0) revert NoOracles();

        bytes memory initData = abi.encodeWithSelector(
            MultiOracleAggregator.initialize.selector,
            address(this), // Factory will be the initial owner
            maxDeviationBps
        );

        // Note: `new` creates a contract at a deterministic address and is not a reentrancy vector
        // The proxy constructor executes synchronously before returning, so this is safe.
        // slither-disable-next-line reentrancy-benign
        ERC1967Proxy proxy = new ERC1967Proxy(aggregatorImplementation, initData);
        MultiOracleAggregator agg = MultiOracleAggregator(address(proxy));

        // CEI: State update before external calls to addOracle/setMaxDeviationBps
        _aggregators[base][quote] = address(agg);

        // External interactions
        for (uint256 i = 0; i < oracles.length; i++) {
            agg.addOracle(base, quote, oracles[i]);
        }
        agg.setMaxDeviationBps(maxDeviationBps);

        // Events after state changes
        emit AggregatorCreated(base, quote, address(agg));
        emit MaxDeviationUpdated(base, quote, maxDeviationBps);

        return address(agg);
    }

    /**
     * @notice Removes an existing aggregator for a given pair
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @custom:access Only callable by owner
     * @dev Reverts if no aggregator is found
     */
    function removeAggregator(address base, address quote) external onlyOwner {
        address aggregator = _aggregators[base][quote];
        if (aggregator == address(0)) revert AggregatorNotFound();
        delete _aggregators[base][quote];
        emit AggregatorRemoved(base, quote);
    }

    /**
     * @notice Transfers the ownership of an aggregator to a new address
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param newOwner New owner address
     * @custom:access Only callable by owner
     * @dev Reverts if no aggregator is found or if the new owner is zero
     */
    function transferAggregatorOwnership(address base, address quote, address newOwner) external onlyOwner {
        address aggregator = _aggregators[base][quote];
        if (aggregator == address(0)) revert AggregatorNotFound();
        if (newOwner == address(0)) revert ZeroAddress();

        MultiOracleAggregator(aggregator).transferOwnership(newOwner);
        emit AggregatorOwnershipTransferred(base, quote, newOwner);
    }

    /**
     * @notice Returns the address of the aggregator for a given asset pair
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @return Address of the registered aggregator, or zero if none exists
     */
    function getAggregator(address base, address quote) external view returns (address) {
        return _aggregators[base][quote];
    }

    /**
     * @notice Returns true if an aggregator exists for a given asset pair
     *         and false otherwise
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @return True if an aggregator exists, false otherwise
     */
    function existsAggregator(address base, address quote) external view returns (bool) {
        return _aggregators[base][quote] != address(0);
    }

    // ────────────────────────────────────────────────
    // ░░ READ: QUOTE RETRIEVAL
    // ────────────────────────────────────────────────

    /**
     * @notice Returns a quote from the registered aggregator using selected method.
     * @param base Address of the base token
     * @param quote Address of the quote token
     * @param inAmount Amount of base token to quote
     * @param useMedian If true, uses median; otherwise, uses average
     * @return quoteAmount Estimated amount of quote token
     */
    function quoteViaFactory(
        address base,
        address quote,
        uint256 inAmount,
        bool useMedian
    ) external returns (uint256 quoteAmount) {
        address aggregator = _aggregators[base][quote];
        if (aggregator == address(0)) revert AggregatorNotFound();

        string memory method = useMedian ? "median" : "average";
        emit QuoteRequested(msg.sender, base, quote, inAmount, method);

        if (useMedian) {
            quoteAmount = MultiOracleAggregator(aggregator).getQuoteMedian(inAmount, base, quote);
        } else {
            quoteAmount = MultiOracleAggregator(aggregator).getQuoteAverage(inAmount, base, quote);
        }
    }
}
