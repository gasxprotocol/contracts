// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title MultiOracleAggregator (UUPS Upgradeable + Trusted Forwarder Compatible)
 * @author edsphinx
 * @notice Aggregates multiple oracle feeds and provides average/median pricing with full traceability.
 * @dev Ensure all adapters return 1e18-scaled quotes. Emits events for tracing and deviation validation.
 */
contract MultiOracleAggregator is OwnableUpgradeable, UUPSUpgradeable {
    // ────────────────────────────────────────────────
    // ░░ CUSTOM ERRORS
    // ────────────────────────────────────────────────

    error ZeroAddress();
    error InvalidPair();
    error ZeroOracle();
    error DuplicateOracle();
    error InvalidIndex();
    error DeviationTooHigh(uint256 bps);
    error NoOracles();
    error NoData();
    error ZeroQuote();

    // ────────────────────────────────────────────────
    // ░░ DATA STRUCTURES
    // ────────────────────────────────────────────────

    /// @notice Address of the trusted forwarder contract for meta-transactions
    address private _trustedForwarder;

    /// @notice Structure holding oracle configuration
    struct OracleInfo {
        address oracleAddress;
        bool enabled;
    }

    /// @notice Structure for deviation validation parameters
    struct DeviationParams {
        address base;
        address quote;
        uint256 amount;
        uint256 refPrice;
    }

    /// @notice Mapping of base ⇒ quote ⇒ list of oracles
    /// @dev Slither false positive: mappings are initialized to empty by default in Solidity
    // slither-disable-next-line uninitialized-state
    mapping(address => mapping(address => OracleInfo[])) private _oracles;

    /// @notice Allowed maximum deviation (in basis points)
    uint256 public maxDeviationBps;

    // ────────────────────────────────────────────────
    // ░░ EVENTS
    // ────────────────────────────────────────────────

    /// @notice Emitted when a new oracle is added to a pair
    event OracleAdded(address indexed base, address indexed quote, address oracle);

    /// @notice Emitted when an oracle is removed by index
    event OracleRemoved(address indexed base, address indexed quote, uint256 index);

    /// @notice Emitted when an oracle is toggled (enabled/disabled)
    event OracleToggled(address indexed base, address indexed quote, uint256 index, bool enabled);

    /// @notice Emitted when an oracle is updated
    event OracleUpdated(
        address indexed base,
        address indexed quote,
        uint256 index,
        address oldOracle,
        address newOracle
    );

    /// @notice Emitted when the maximum deviation is updated
    event MaxDeviationUpdated(uint256 previousBps, uint256 newBps);

    /// @notice Emitted when the trusted forwarder is updated
    event TrustedForwarderUpdated(address previousForwarder, address newForwarder);

    /// @notice Emitted when a quote is successfully used
    event QuoteUsed(
        address indexed base,
        address indexed quote,
        address oracle,
        uint256 inputAmount, // This parameter is not used in the event.
        uint256 outputQuote
    );

    /// @notice Emitted when a quote is rejected due to deviation
    event QuoteDeviationRejected(
        address indexed base,
        address indexed quote,
        address oracle,
        uint256 inputAmount,
        uint256 quoteValue,
        uint256 referenceQuote
    );

    // ────────────────────────────────────────────────
    // ░░ CONSTRUCTOR / INITIALIZER
    // ────────────────────────────────────────────────

    /**
     * @notice Initializes the contract with the owner and deviation settings
     * @param initialOwner The owner to set
     * @param deviationBps Max allowed deviation in basis points
     */
    function initialize(address initialOwner, uint256 deviationBps) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (deviationBps > 10_000) revert DeviationTooHigh(deviationBps);
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        maxDeviationBps = deviationBps;
    }

    /// @notice Required by UUPS pattern - only owner can upgrade
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // Authorization is handled by onlyOwner modifier
        // newImplementation validation is handled by UUPS proxy
        (newImplementation); // Silence unused variable warning
    }

    /// @dev Ensures both tokens are valid and not equal
    modifier onlyValidPair(address base, address quote) {
        if (base == address(0) || quote == address(0)) revert ZeroAddress();
        if (base == quote) revert InvalidPair();
        _;
    }

    // ────────────────────────────────────────────────
    // ░░ ADMIN: ORACLE CONFIGURATION
    // ────────────────────────────────────────────────

    /**
     * @notice Adds an oracle for a base/quote pair
     * @param base Token being priced
     * @param quote Reference token
     * @param oracle Oracle address
     * @custom:security onlyOwner
     */
    function addOracle(address base, address quote, address oracle) external onlyOwner onlyValidPair(base, quote) {
        if (oracle == address(0)) revert ZeroOracle();
        OracleInfo[] storage list = _oracles[base][quote];
        for (uint256 i; i < list.length; i++) {
            if (list[i].oracleAddress == oracle) revert DuplicateOracle();
        }
        list.push(OracleInfo(oracle, true));
        emit OracleAdded(base, quote, oracle);
    }

    /**
     * @notice Removes an oracle from a pair by index
     * @param base Token being priced
     * @param quote Reference token
     * @param index Oracle index
     * @custom:security onlyOwner
     */
    function removeOracle(address base, address quote, uint256 index) external onlyOwner {
        OracleInfo[] storage list = _oracles[base][quote];
        if (index >= list.length) revert InvalidIndex();
        emit OracleRemoved(base, quote, index);
        list[index] = list[list.length - 1];
        list.pop();
    }

    /**
     * @notice Replaces an existing oracle
     * @param base Token being priced
     * @param quote Reference token
     * @param index Oracle index
     * @param newOracle New oracle address
     * @custom:security onlyOwner
     */
    function updateOracle(address base, address quote, uint256 index, address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroOracle();
        OracleInfo[] storage list = _oracles[base][quote];
        if (index >= list.length) revert InvalidIndex();
        for (uint256 i; i < list.length; i++) {
            if (list[i].oracleAddress == newOracle) revert DuplicateOracle();
        }
        address old = list[index].oracleAddress;
        list[index].oracleAddress = newOracle;
        emit OracleUpdated(base, quote, index, old, newOracle);
    }

    /**
     * @notice Enables or disables an oracle
     * @param base Token being priced
     * @param quote Reference token
     * @param index Oracle index
     * @param enabled True to enable, false to disable
     * @custom:security onlyOwner
     */
    function toggleOracle(address base, address quote, uint256 index, bool enabled) external onlyOwner {
        OracleInfo[] storage list = _oracles[base][quote];
        if (index >= list.length) revert InvalidIndex();
        list[index].enabled = enabled;
        emit OracleToggled(base, quote, index, enabled);
    }

    /**
     * @notice Sets the maximum deviation allowed between quotes
     * @param bps Deviation in basis points
     * @custom:security onlyOwner
     */
    function setMaxDeviationBps(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert DeviationTooHigh(bps);
        uint256 previousBps = maxDeviationBps;
        maxDeviationBps = bps;
        emit MaxDeviationUpdated(previousBps, bps);
    }

    /**
     * @notice Sets the trusted forwarder for meta-transactions
     * @param forwarder Address of the trusted forwarder
     * @custom:security onlyOwner
     */
    function setTrustedForwarder(address forwarder) external onlyOwner {
        address previousForwarder = _trustedForwarder;
        _trustedForwarder = forwarder;
        emit TrustedForwarderUpdated(previousForwarder, forwarder);
    }

    // ────────────────────────────────────────────────
    // ░░ READ: QUOTE RETRIEVAL
    // ────────────────────────────────────────────────

    /**
     * @notice Returns average quote after filtering
     * @param amount Input amount
     * @param base Token being priced
     * @param quote Reference token
     * @return Quote in reference token
     */
    function getQuoteAverage(uint256 amount, address base, address quote) external returns (uint256) {
        OracleInfo[] storage list = _oracles[base][quote];
        if (list.length == 0) revert NoOracles();
        uint256[] memory quotes = new uint256[](list.length);
        address[] memory oracleAddrs = new address[](list.length);
        uint256 count = 0;

        for (uint256 i = 0; i < list.length; i++) {
            if (!list[i].enabled) continue;
            try IPriceOracle(list[i].oracleAddress).getQuote(amount, base, quote) returns (uint256 q) {
                if (q == 0) revert ZeroQuote();
                quotes[count] = q;
                oracleAddrs[count] = list[i].oracleAddress;
                count++;
                emit QuoteUsed(base, quote, list[i].oracleAddress, amount, q);
            } catch {}
        }

        if (count == 0) revert NoData();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) sum += quotes[i];
        uint256 avg = sum / count;

        _validateDeviation(quotes, oracleAddrs, count, DeviationParams(base, quote, amount, avg));
        return avg;
    }

    /** @notice Returns average quote after filtering as view
     *  @param amount Input amount
     *  @param base Token being priced
     *  @param quote Reference token
     *  @return Quote in reference token
     */
    function computeQuoteAverage(uint256 amount, address base, address quote) public view returns (uint256) {
        OracleInfo[] storage list = _oracles[base][quote];
        if (list.length == 0) revert NoOracles();

        uint256[] memory quotes = new uint256[](list.length);
        uint256 count = 0;

        for (uint256 i = 0; i < list.length; i++) {
            if (!list[i].enabled) continue;
            try IPriceOracle(list[i].oracleAddress).getQuote(amount, base, quote) returns (uint256 q) {
                if (q == 0) revert ZeroQuote();
                quotes[count++] = q;
            } catch {}
        }

        if (count == 0) revert NoData();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) sum += quotes[i];
        uint256 avg = sum / count;

        for (uint256 i = 0; i < count; i++) {
            uint256 diff = quotes[i] > avg ? quotes[i] - avg : avg - quotes[i];
            uint256 deviationBps = (diff * 10_000) / avg;
            if (deviationBps > maxDeviationBps) revert DeviationTooHigh(deviationBps);
        }

        return avg;
    }

    /**
     * @notice Returns median quote after filtering
     * @param amount Input amount
     * @param base Token being priced
     * @param quote Reference token
     * @return Quote in reference token
     */
    function getQuoteMedian(uint256 amount, address base, address quote) external returns (uint256) {
        OracleInfo[] storage list = _oracles[base][quote];
        if (list.length == 0) revert NoOracles();
        uint256[] memory quotes = new uint256[](list.length);
        address[] memory oracleAddrs = new address[](list.length);
        uint256 count = 0;

        for (uint256 i = 0; i < list.length; i++) {
            if (!list[i].enabled) continue;
            try IPriceOracle(list[i].oracleAddress).getQuote(amount, base, quote) returns (uint256 q) {
                if (q == 0) revert ZeroQuote();
                quotes[count] = q;
                oracleAddrs[count] = list[i].oracleAddress;
                count++;
                emit QuoteUsed(base, quote, list[i].oracleAddress, amount, q);
            } catch {}
        }

        if (count == 0) revert NoData();
        uint256[] memory valid = new uint256[](count);
        for (uint256 i = 0; i < count; i++) valid[i] = quotes[i];
        uint256 med = _median(valid);

        _validateDeviation(quotes, oracleAddrs, count, DeviationParams(base, quote, amount, med));
        return med;
    }

    /**
     * @notice Returns median quote after filtering as view
     * @param amount Input amount
     * @param base Token being priced
     * @param quote Reference token
     * @return Quote in reference token
     */
    function computeQuoteMedian(uint256 amount, address base, address quote) public view returns (uint256) {
        OracleInfo[] storage list = _oracles[base][quote];
        if (list.length == 0) revert NoOracles();
        uint256[] memory quotes = new uint256[](list.length);
        uint256 count = 0;

        for (uint256 i = 0; i < list.length; i++) {
            if (!list[i].enabled) continue;
            try IPriceOracle(list[i].oracleAddress).getQuote(amount, base, quote) returns (uint256 q) {
                if (q == 0) revert ZeroQuote();
                quotes[count++] = q;
            } catch {}
        }

        if (count == 0) revert NoData();
        uint256[] memory valid = new uint256[](count);
        for (uint256 i = 0; i < count; i++) valid[i] = quotes[i];
        uint256 med = _median(valid);

        for (uint256 i = 0; i < count; i++) {
            uint256 diff = quotes[i] > med ? quotes[i] - med : med - quotes[i];
            uint256 deviationBps = (diff * 10_000) / med;
            if (deviationBps > maxDeviationBps) {
                revert DeviationTooHigh(deviationBps);
            }
        }
        return med;
    }

    /**
     * @dev Internal method to compute the median value
     * @param arr Array of quote values
     * @return Median value
     */
    function _median(uint256[] memory arr) internal pure returns (uint256) {
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = i + 1; j < arr.length; j++) {
                if (arr[j] < arr[i]) (arr[i], arr[j]) = (arr[j], arr[i]);
            }
        }
        return arr[arr.length / 2];
    }

    /**
     * @dev Internal method to validate deviation and emit events
     * @param quotes Array of quote values
     * @param oracleAddrs Array of oracle addresses corresponding to quotes
     * @param count Number of valid quotes
     * @param params Deviation validation parameters (base, quote, amount, refPrice)
     */
    function _validateDeviation(
        uint256[] memory quotes,
        address[] memory oracleAddrs,
        uint256 count,
        DeviationParams memory params
    ) internal {
        for (uint256 i; i < count; i++) {
            uint256 diff = quotes[i] > params.refPrice ? quotes[i] - params.refPrice : params.refPrice - quotes[i];
            uint256 deviationBps = (diff * 10_000) / params.refPrice;
            if (deviationBps > maxDeviationBps) {
                emit QuoteDeviationRejected(params.base, params.quote, oracleAddrs[i], params.amount, quotes[i], params.refPrice);
                revert DeviationTooHigh(deviationBps);
            }
        }
    }

    // ────────────────────────────────────────────────
    // ░░ VIEW: ORACLE INSPECTION
    // ────────────────────────────────────────────────

    /**
     * @notice Returns list of registered oracles for a pair
     * @param base Token being priced
     * @param quote Reference token
     * @return Array of OracleInfo structs
     */
    function getOracles(address base, address quote) external view returns (OracleInfo[] memory) {
        return _oracles[base][quote];
    }

    /**
     * @notice Returns the number of oracles for a pair
     * @param base Token being priced
     * @param quote Reference token
     * @return Number of registered oracles
     */
    function oracleCount(address base, address quote) external view returns (uint256) {
        return _oracles[base][quote].length;
    }

    // ────────────────────────────────────────────────
    // ░░ ERC2771ContextUpgradeable: METATRANSACTIONS
    // ────────────────────────────────────────────────

    /// @custom:security ERC2771ContextUpgradeable
    function _msgSender() internal view override returns (address sender) {
        if (isTrustedForwarder(msg.sender)) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /// @custom:security ERC2771ContextUpgradeable
    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender)) {
            return msg.data[:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }

    /// @custom:security ERC2771ContextUpgradeable
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    // ────────────────────────────────────────────────
    // ░░ EMERGENCY: ETH RECOVERY
    // ────────────────────────────────────────────────

    /// @notice Emitted when ETH is withdrawn from the contract
    event EthWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Withdraws any ETH accidentally sent to this contract
     * @param to Recipient address
     * @custom:security onlyOwner
     * @dev This contract is not designed to hold ETH. This function exists
     *      to recover any ETH accidentally sent to it.
     */
    function emergencyWithdrawEth(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance < 1) revert NoData(); // Changed from == 0 to avoid strict equality warning
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH transfer failed");
        emit EthWithdrawn(to, balance);
    }
}
