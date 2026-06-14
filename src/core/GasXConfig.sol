// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GasXConfig
 * @author edsphinx
 * @notice Stores and manages configuration data for GasX protocol:
 *         - oracleSigner: address authorised to sign off-chain subsidy data
 *         - maxUsdPerSelector: maps function selectors to max spend in USDC
 * @dev Used by GasX Paymaster to enforce subsidy limits and oracle verification logic.
 */
contract GasXConfig {
    // ────────────────────────────────────────────────
    // ░░  STATE VARIABLES
    // ────────────────────────────────────────────────

    /// @notice Owner of the contract (immutable)
    address public immutable owner;

    /// @notice Address of the authorized signer used for oracle-signed payload validation
    address public oracleSigner;

    /// @notice Mapping of function selectors to their max USD cap (6 decimals)
    mapping(bytes4 => uint256) public maxUsdPerSelector;

    // ────────────────────────────────────────────────
    // ░░  EVENTS
    // ────────────────────────────────────────────────

    /// @notice Emitted when the oracle signer is changed
    /// @param previousSigner The previous oracle signer address
    /// @param newSigner The new authorized oracle signer address
    event OracleSignerUpdated(address indexed previousSigner, address indexed newSigner);

    /// @notice Emitted when a selector's max USD subsidy is set or updated
    /// @param selector Function selector (4-byte method signature)
    /// @param previousMaxUsd Previous max USD value (6 decimals)
    /// @param newMaxUsd New max allowed subsidy in USD (6 decimals)
    event MaxUsdSet(bytes4 indexed selector, uint256 previousMaxUsd, uint256 newMaxUsd);

    // ────────────────────────────────────────────────
    // ░░  ERRORS
    // ────────────────────────────────────────────────

    /// @notice Thrown when zero address is provided
    error ZeroAddress();
    /// @notice Thrown when array lengths don't match
    error LengthMismatch();

    // ────────────────────────────────────────────────
    // ░░  CONSTRUCTOR
    // ────────────────────────────────────────────────

    /**
     * @notice Deploys the config with the initial signer
     * @param _oracleSigner Initial address allowed to sign oracle payloads
     */
    constructor(address _oracleSigner) {
        if (_oracleSigner == address(0)) revert ZeroAddress();
        owner = msg.sender;
        oracleSigner = _oracleSigner;
    }

    // ────────────────────────────────────────────────
    // ░░  MODIFIERS
    // ────────────────────────────────────────────────

    /// @dev Restricts function to the contract owner
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ────────────────────────────────────────────────
    // ░░  ADMIN FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Updates the signer used to verify oracle payloads
     * @dev Only callable by the contract owner
     * @param newSigner Address of the new oracle signer
     * @custom:security onlyOwner
     */
    function setOracleSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        address previousSigner = oracleSigner;
        oracleSigner = newSigner;
        emit OracleSignerUpdated(previousSigner, newSigner);
    }

    /**
     * @notice Sets the max USD subsidy allowed for a given function selector
     * @dev Only callable by the contract owner
     * @param selector Function selector (4-byte method signature)
     * @param maxUsd Subsidy limit in USD (6 decimals)
     * @custom:security onlyOwner
     */
    function setMaxUsd(bytes4 selector, uint256 maxUsd) external onlyOwner {
        uint256 previousMaxUsd = maxUsdPerSelector[selector];
        maxUsdPerSelector[selector] = maxUsd;
        emit MaxUsdSet(selector, previousMaxUsd, maxUsd);
    }

    /**
     * @notice Batch update of max USD subsidy for multiple selectors
     * @dev Only callable by the contract owner
     * @param selectors Array of function selectors (4-byte signatures)
     * @param maxUsds Array of max USD values (6 decimals)
     * @custom:security onlyOwner
     */
    function bulkSetMaxUsd(bytes4[] calldata selectors, uint256[] calldata maxUsds) external onlyOwner {
        if (selectors.length != maxUsds.length) revert LengthMismatch();
        for (uint256 i = 0; i < selectors.length; i++) {
            uint256 previousMaxUsd = maxUsdPerSelector[selectors[i]];
            maxUsdPerSelector[selectors[i]] = maxUsds[i];
            emit MaxUsdSet(selectors[i], previousMaxUsd, maxUsds[i]);
        }
    }

    // ────────────────────────────────────────────────
    // ░░  VIEW FUNCTIONS
    // ────────────────────────────────────────────────

    /**
     * @notice Returns the max allowed USD subsidy for a given selector
     * @param selector Function selector to query (4-byte signature)
     * @return maxUsd Max allowed subsidy in USD (6 decimals)
     */
    function getMaxUsd(bytes4 selector) external view returns (uint256 maxUsd) {
        return maxUsdPerSelector[selector];
    }

    /**
     * @notice Returns an array of max USD limits for the given selectors
     * @param selectors List of selectors to query (4-byte signatures)
     * @return results Array of USD caps (6 decimals) matching input selectors
     */
    function getAllLimits(bytes4[] calldata selectors) external view returns (uint256[] memory results) {
        results = new uint256[](selectors.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            results[i] = maxUsdPerSelector[selectors[i]];
        }
    }
}
