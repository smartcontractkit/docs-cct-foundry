// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {ChainHandlers} from "../utils/ChainHandlers.s.sol";
import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {PoolVersion} from "../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {CctActions, ITokenPoolV150} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Configures cross-chain lanes on the source TokenPool by calling applyChainUpdates.
/// Sets the remote pool(s), remote token, and optional rate limiter configs per destination chain.
/// Idempotent: if a destination chain is already configured, the existing config is removed and replaced.
///
/// Lane updates dispatch on the source pool's on-chain contract version (see docs/pool-versions.md):
/// pools 1.5.1 and later use the modern removes/adds applyChainUpdates shape, while a 1.5.0 pool uses
/// its own single-argument encoding, announced in the console as "Pool contract version 1.5.0
/// detected; using the 1.5.0 lane-update encoding."
///
/// Supports two input modes, chosen by whether VIA_JSON_FILE is set:
///
/// ─── JSON FILE MODE ────────────────────────────────────────────────────────
/// VIA_JSON_FILE=true  Reads config from script/input/apply-chain-updates.json.
///
/// The JSON file allows configuring multiple destination chains and multiple remote pool addresses
/// per chain in a single transaction — something that is impractical via inline CLI args.
///
/// JSON schema:
///   {
///     "sourcePool": "0x...",          // optional — overrides TOKEN_POOL / <CHAIN>_TOKEN_POOL env var
///     "remoteChains": [
///       {
///         "destChain": "MANTLE_SEPOLIA",         // required — chain name identifier
///         "destChainFamily": "evm",              // optional — auto-detected; set "svm" for Solana
///         "destChainSelector": 0,                // optional — auto-detected from destChain
///         "destPools": ["0x...", "0x..."],        // required — one or more remote pool addresses
///         "destToken": "0x...",                  // required — remote token address
///         "outboundRateLimit": {                 // optional — defaults to disabled
///           "enabled": false,
///           "capacity": 0,
///           "rate": 0
///         },
///         "inboundRateLimit": {                  // optional — defaults to disabled
///           "enabled": false,
///           "capacity": 0,
///           "rate": 0
///         }
///       }
///     ]
///   }
///
/// See script/input/apply-chain-updates.json for a working example.
///
/// ─── CLI / ENV VAR MODE (single destination chain) ─────────────────────────
/// Environment Variables (required):
///   DEST_CHAIN                    - The destination chain name (e.g. MANTLE_SEPOLIA)
///   <SOURCE_CHAIN>_TOKEN_POOL     - Address of the token pool on the source chain
///                                   (or use the chain-agnostic alias: TOKEN_POOL=0x...)
///
/// Environment Variables (EVM destinations — at least one form required):
///   DEST_TOKEN_POOL               - EVM address of the token pool on the destination chain
///                                   (overrides the chain-specific <DEST_CHAIN>_TOKEN_POOL var)
///   <DEST_CHAIN>_TOKEN_POOL       - EVM address of the token pool on the destination chain
///   DEST_TOKEN                    - EVM address of the token on the destination chain
///                                   (overrides the chain-specific <DEST_CHAIN>_TOKEN var)
///   <DEST_CHAIN>_TOKEN            - EVM address of the token on the destination chain
///
/// Environment Variables (non-EVM destinations):
///   DEST_CHAIN_FAMILY             - "svm"/"solana" (default: "evm")
///                                   (auto-detected for SOLANA_DEVNET)
///   DEST_CHAIN_SELECTOR           - uint64 chain selector for the destination chain
///                                   (auto-detected for SOLANA_DEVNET)
///   DEST_TOKEN_POOL               - Destination pool address in its native format
///                                   (base58 for SVM)
///   DEST_TOKEN                    - Destination token address in its native format
///
/// Environment Variables (optional — rate limiting disabled by default):
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, token bucket capacity (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, token bucket capacity (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_RATE       - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///
/// Rate-limit input resolution ladder (CLI mode, per direction — matching the repo's
/// inline > env > registry idiom):
///   1. Any of the direction's rate-limit env vars set → the env values win, byte-for-byte the
///      historical behavior above. When the local chain config declares a diverging lanes{} policy
///      for the destination, a one-line console notice names both values (`make doctor` WARNs until
///      reconciled) and the closing output prints the exact `make add-lane` remediation command.
///   2. Env vars unset → the declared `lanes{}` policy in `config/chains/<local>.json` supplies the
///      bucket: `capacity`/`rate` drive the outbound bucket (enabled iff either is non-zero, the
///      same inference the doctor's lanes rung uses); the optional `inbound{capacity,rate}` block
///      drives the inbound bucket, and an ABSENT inbound block keeps the env-absent default
///      (disabled).
///   3. Neither env vars nor a lanes{} entry → the historical default stands: disabled buckets
///      (the console says so).
/// lanes{} is owner intent — an env-driven apply never writes it back. The printed `make add-lane`
/// hint plus the doctor WARN close the loop through a reviewed edit by design.
contract ApplyChainUpdates is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev Bundles resolved destination chain parameters into a single struct to
    ///      avoid exceeding the EVM's 16-slot stack limit inside run().
    struct DestChainParams {
        uint64 chainSelector;
        string displayName;
        /// @dev Only used in CLI mode (single-pool). In JSON mode rawPoolAddresses is used instead.
        string rawPoolAddress;
        string rawTokenAddress;
        /// @dev Only used in CLI mode (single-pool).
        bytes poolEncoded;
        bytes tokenEncoded;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Entry point
    // ─────────────────────────────────────────────────────────────────────────

    string internal constant JSON_INPUT_FILE = "script/input/apply-chain-updates.json";

    function run() external {
        helperConfig = new HelperConfig();

        if (vm.envOr("VIA_JSON_FILE", false)) {
            _runFromJson();
        } else {
            _runFromEnv();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // JSON file mode  — multiple chains, multiple pools per chain
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reads the JSON config file and applies chain updates for every entry in remoteChains[].
    ///      All chain updates (removals + additions) are batched into a single applyChainUpdates call.
    function _runFromJson() internal {
        uint256 sourceChainId = block.chainid;
        string memory json = vm.readFile(JSON_INPUT_FILE);

        // Resolve source pool — JSON "sourcePool" field takes priority, then falls back to env vars.
        address poolAddress;
        if (vm.keyExistsJson(json, ".sourcePool") && bytes(vm.parseJsonString(json, ".sourcePool")).length > 0) {
            poolAddress = vm.parseJsonAddress(json, ".sourcePool");
        } else {
            poolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        }
        require(
            poolAddress != address(0),
            string.concat(
                "Token pool not deployed on source chain. Set 'sourcePool' in the JSON file, or set TOKEN_POOL / ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable."
            )
        );

        uint256 numChains = _jsonArrayLength(json, ".remoteChains");
        require(numChains > 0, "JSON file must contain at least one entry in 'remoteChains'.");

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Apply Chain Updates (JSON mode)");
        console.log("========================================");
        console.log(string.concat("Source Chain:  ", helperConfig.getChainName(sourceChainId)));
        console.log(string.concat("Token Pool:    ", vm.toString(poolAddress)));
        console.log(string.concat("Input File:    ", JSON_INPUT_FILE));
        console.log(string.concat("Remote Chains: ", vm.toString(numChains)));
        console.log("========================================");
        console.log("");

        TokenPool poolContract = TokenPool(poolAddress);

        // Single pass: build all updates, detect which chains are already configured, and log.
        bool[] memory shouldRemove = new bool[](numChains);
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](numChains);
        uint256 numRemovals = 0;

        for (uint256 i = 0; i < numChains; i++) {
            chainUpdates[i] = _buildChainUpdateFromJson(json, i);
            shouldRemove[i] = poolContract.isSupportedChain(chainUpdates[i].remoteChainSelector);
            if (shouldRemove[i]) {
                numRemovals++;
                console.log(
                    string.concat(
                        unicode"  ⚠️  [",
                        vm.toString(i),
                        "] Existing config for chain selector ",
                        vm.toString(chainUpdates[i].remoteChainSelector),
                        " will be replaced."
                    )
                );
            } else {
                console.log(
                    string.concat(
                        "  [",
                        vm.toString(i),
                        "] New chain selector ",
                        vm.toString(chainUpdates[i].remoteChainSelector),
                        " will be added."
                    )
                );
            }
        }

        uint64[] memory chainSelectorRemovals = new uint64[](numRemovals);
        uint256 removalIdx = 0;
        for (uint256 i = 0; i < numChains; i++) {
            if (shouldRemove[i]) chainSelectorRemovals[removalIdx++] = chainUpdates[i].remoteChainSelector;
        }

        console.log("");

        console.log(
            string.concat("[Step 1] Applying chain updates to pool on ", helperConfig.getChainName(sourceChainId))
        );
        (PoolVersions.Version poolVersion, string memory poolTypeAndVersion) = PoolVersion.resolve(poolAddress);
        console.log(string.concat("Pool contract: ", poolTypeAndVersion));
        executeCalls(_buildLaneUpdateCalls(poolVersion, poolAddress, chainSelectorRemovals, chainUpdates, shouldRemove));
        console.log(unicode"✅ Chain updates applied successfully!");

        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Chain Updates Complete on ", helperConfig.getChainName(sourceChainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:               ", vm.toString(poolAddress)));
        console.log(string.concat("Remote chains configured: ", vm.toString(numChains)));
        console.log(
            string.concat(
                "Explorer:                 ", helperConfig.getExplorerUrl(sourceChainId, "/address/", poolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev Holds chain metadata resolved from a JSON remoteChains[] entry.
    struct JsonChainMeta {
        uint64 chainSelector;
        string displayName;
        string destChainFamilyStr;
        ChainHandlers.ChainFamily destChainFamily;
    }

    /// @dev Holds encoded address arrays resolved from a JSON remoteChains[] entry.
    struct JsonChainAddrs {
        bytes tokenEncoded;
        bytes[] encodedPools;
        string rawTokenAddress;
        string[] rawPoolAddresses;
    }

    /// @dev Resolves chain selector and builds a ChainUpdate struct for remoteChains[index].
    ///      Split into sub-helpers to stay within the EVM's 16-slot stack limit.
    function _buildChainUpdateFromJson(string memory json, uint256 index)
        internal
        view
        returns (TokenPool.ChainUpdate memory update)
    {
        string memory prefix = string.concat(".remoteChains[", vm.toString(index), "]");

        JsonChainMeta memory meta = _resolveJsonChainMeta(json, prefix, index);

        JsonChainAddrs memory addrs =
            _resolveJsonAddresses(json, prefix, index, meta.destChainFamily, meta.destChainFamilyStr);

        RateLimiter.Config memory outbound = _parseRateLimitFromJson(json, string.concat(prefix, ".outboundRateLimit"));
        RateLimiter.Config memory inbound = _parseRateLimitFromJson(json, string.concat(prefix, ".inboundRateLimit"));

        _logJsonChainEntry(index, meta, addrs, outbound, inbound);

        update = TokenPool.ChainUpdate({
            remoteChainSelector: meta.chainSelector,
            remotePoolAddresses: addrs.encodedPools,
            remoteTokenAddress: addrs.tokenEncoded,
            outboundRateLimiterConfig: outbound,
            inboundRateLimiterConfig: inbound
        });
    }

    /// @dev Resolves chain selector, display name, and family for a remoteChains[index] entry.
    function _resolveJsonChainMeta(string memory json, string memory prefix, uint256 index)
        internal
        view
        returns (JsonChainMeta memory meta)
    {
        string memory destChainName = vm.parseJsonString(json, string.concat(prefix, ".destChain"));
        HelperConfig.NetworkConfig memory destConfig = helperConfig.getDestChainConfig(destChainName);

        if (vm.keyExistsJson(json, string.concat(prefix, ".destChainFamily"))) {
            meta.destChainFamilyStr = vm.parseJsonString(json, string.concat(prefix, ".destChainFamily"));
        } else {
            meta.destChainFamilyStr = bytes(destConfig.chainFamily).length > 0 ? destConfig.chainFamily : string("evm");
        }
        meta.destChainFamily = ChainHandlers.parseChainFamily(meta.destChainFamilyStr);

        if (vm.keyExistsJson(json, string.concat(prefix, ".destChainSelector"))) {
            meta.chainSelector = uint64(vm.parseJsonUint(json, string.concat(prefix, ".destChainSelector")));
        } else {
            meta.chainSelector = destConfig.chainSelector;
        }
        require(
            meta.chainSelector != 0,
            string.concat(
                "Chain selector is 0 for remoteChains[",
                vm.toString(index),
                "]. Set 'destChainSelector' in the JSON entry or use a recognized 'destChain' name."
            )
        );

        meta.displayName = bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;
    }

    /// @dev Validates and encodes pool and token addresses for a remoteChains[index] entry.
    function _resolveJsonAddresses(
        string memory json,
        string memory prefix,
        uint256 index,
        ChainHandlers.ChainFamily destChainFamily,
        string memory destChainFamilyStr
    ) internal pure returns (JsonChainAddrs memory addrs) {
        addrs.rawTokenAddress = vm.parseJsonString(json, string.concat(prefix, ".destToken"));
        require(
            ChainHandlers.validateChainAddress(addrs.rawTokenAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " token address: ", addrs.rawTokenAddress)
        );
        addrs.tokenEncoded = ChainHandlers.prepareChainAddressData(addrs.rawTokenAddress, destChainFamily);

        addrs.rawPoolAddresses = vm.parseJsonStringArray(json, string.concat(prefix, ".destPools"));
        require(
            addrs.rawPoolAddresses.length > 0,
            string.concat("remoteChains[", vm.toString(index), "].destPools must contain at least one address.")
        );

        addrs.encodedPools = new bytes[](addrs.rawPoolAddresses.length);
        for (uint256 p = 0; p < addrs.rawPoolAddresses.length; p++) {
            require(
                ChainHandlers.validateChainAddress(addrs.rawPoolAddresses[p], destChainFamily),
                string.concat("Invalid ", destChainFamilyStr, " pool address: ", addrs.rawPoolAddresses[p])
            );
            addrs.encodedPools[p] = ChainHandlers.prepareChainAddressData(addrs.rawPoolAddresses[p], destChainFamily);
        }
    }

    /// @dev Logs a summary of one remoteChains[index] entry.
    function _logJsonChainEntry(
        uint256 index,
        JsonChainMeta memory meta,
        JsonChainAddrs memory addrs,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) internal pure {
        console.log(string.concat("  [", vm.toString(index), "] ", meta.displayName));
        console.log(string.concat("      Selector:       ", vm.toString(meta.chainSelector)));
        console.log(string.concat("      Family:         ", meta.destChainFamilyStr));
        console.log(string.concat("      Token:          ", addrs.rawTokenAddress));
        console.log(string.concat("      Pools:          ", vm.toString(addrs.rawPoolAddresses.length)));
        for (uint256 p = 0; p < addrs.rawPoolAddresses.length; p++) {
            console.log(string.concat("        [", vm.toString(p), "] ", addrs.rawPoolAddresses[p]));
        }
        console.log(string.concat("      Outbound RL:    enabled=", vm.toString(outbound.isEnabled)));
        console.log(string.concat("      Inbound RL:     enabled=", vm.toString(inbound.isEnabled)));
    }

    /// @dev Parses an optional rate limit object from JSON. Returns a disabled config if the key is absent.
    function _parseRateLimitFromJson(string memory json, string memory key)
        internal
        view
        returns (RateLimiter.Config memory config)
    {
        if (!vm.keyExistsJson(json, key)) {
            return RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
        }
        bool enabled = vm.parseJsonBool(json, string.concat(key, ".enabled"));
        uint128 capacity = enabled ? uint128(vm.parseJsonUint(json, string.concat(key, ".capacity"))) : 0;
        uint128 rate = enabled ? uint128(vm.parseJsonUint(json, string.concat(key, ".rate"))) : 0;
        config = RateLimiter.Config({isEnabled: enabled, capacity: capacity, rate: rate});
    }

    /// @dev Returns the length of a JSON array at `arrayKey` by probing indices until one is missing.
    ///      forge-std does not expose a direct array-length function, so we probe until keyExistsJson returns false.
    function _jsonArrayLength(string memory json, string memory arrayKey) internal view returns (uint256 length) {
        while (vm.keyExistsJson(json, string.concat(arrayKey, "[", vm.toString(length), "]"))) {
            length++;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CLI / env var mode  — single destination chain (original behaviour)
    // ─────────────────────────────────────────────────────────────────────────

    function _runFromEnv() internal {
        // Get destination chain name from environment variable
        string memory destChainName = vm.envString("DEST_CHAIN");

        // Look up chain config by name — covers both EVM and non-EVM destinations.
        // DEST_CHAIN_FAMILY / DEST_CHAIN_SELECTOR env vars always take precedence.
        HelperConfig.NetworkConfig memory destConfig = helperConfig.getDestChainConfig(destChainName);
        string memory destChainFamilyStr = vm.envOr(
            "DEST_CHAIN_FAMILY", bytes(destConfig.chainFamily).length > 0 ? destConfig.chainFamily : string("evm")
        );
        ChainHandlers.ChainFamily destChainFamily = ChainHandlers.parseChainFamily(destChainFamilyStr);

        uint256 sourceChainId = block.chainid;

        bool isEvmDest = destChainFamily == ChainHandlers.ChainFamily.EVM;

        // Get deployed pool address from source chain (always EVM)
        address poolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        require(
            poolAddress != address(0),
            string.concat(
                "Token pool not deployed on source chain. Set TOKEN_POOL or ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable."
            )
        );

        // Resolve all destination chain parameters into a single struct to keep
        // the local-variable count in run() within the EVM's 16-slot stack limit.
        DestChainParams memory dest =
            _resolveDestChainParams(destChainName, destChainFamilyStr, destChainFamily, isEvmDest, destConfig);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Apply Chain Updates");
        console.log("========================================");
        console.log(string.concat("Chain:        ", helperConfig.getChainName(sourceChainId)));
        console.log(string.concat("Remote Chain: ", dest.displayName));
        console.log(string.concat("Token Pool:   ", vm.toString(poolAddress)));
        console.log(string.concat("Action:       ", "Configure cross-chain lane"));
        console.log("========================================");
        console.log("");

        RateLimitResolution memory rateLimits = _resolveRateLimiterConfigs(destChainName, dest.chainSelector);

        console.log("Chain Update Parameters:");
        console.log(string.concat("  Source Pool:                  ", vm.toString(poolAddress)));
        console.log(string.concat("  Destination Chain Selector:   ", vm.toString(dest.chainSelector)));
        console.log(string.concat("  Destination Chain Family:     ", destChainFamilyStr));
        console.log(string.concat("  Destination Pool:             ", dest.rawPoolAddress));
        console.log(string.concat("  Destination Token:            ", dest.rawTokenAddress));
        console.log(string.concat("  Outbound Rate Limit Enabled:  ", vm.toString(rateLimits.outbound.isEnabled)));
        console.log(string.concat("  Outbound Rate Limit Rate:     ", vm.toString(uint256(rateLimits.outbound.rate))));
        console.log(string.concat("  Inbound Rate Limit Enabled:   ", vm.toString(rateLimits.inbound.isEnabled)));
        console.log(
            string.concat("  Inbound Rate Limit Capacity:  ", vm.toString(uint256(rateLimits.inbound.capacity)))
        );
        console.log(string.concat("  Inbound Rate Limit Rate:      ", vm.toString(uint256(rateLimits.inbound.rate))));
        _logRateLimitResolution(rateLimits, destChainName);
        console.log("");

        console.log(
            string.concat("\n[Step 1] Applying chain updates to pool on ", helperConfig.getChainName(sourceChainId))
        );

        _applyChainUpdateToPool(poolAddress, dest, rateLimits.outbound, rateLimits.inbound);

        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Chain Updates Complete on ", helperConfig.getChainName(sourceChainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(poolAddress)));
        console.log(
            string.concat("Remote Chain: ", dest.displayName, " (Selector: ", vm.toString(dest.chainSelector), ")")
        );
        console.log(string.concat("Remote Pool:  ", dest.rawPoolAddress));
        console.log(
            string.concat("Explorer:     ", helperConfig.getExplorerUrl(sourceChainId, "/address/", poolAddress))
        );
        console.log("========================================");
        _logAddLaneHint(rateLimits);
        console.log("");
    }

    /// @dev Resolves all destination-chain parameters (selector, display name, validated
    ///      and encoded pool/token addresses) into a DestChainParams struct.
    ///      Extracted from _runFromEnv() to keep its stack depth within the EVM's 16-slot limit.
    function _resolveDestChainParams(
        string memory destChainName,
        string memory destChainFamilyStr,
        ChainHandlers.ChainFamily destChainFamily,
        bool isEvmDest,
        HelperConfig.NetworkConfig memory destConfig
    ) internal view returns (DestChainParams memory dest) {
        // Resolve destination chain selector from the config; DEST_CHAIN_SELECTOR always overrides.
        // Required for unknown chains (chainSelector == 0 in the zero config).
        uint64 chainSelector = uint64(vm.envOr("DEST_CHAIN_SELECTOR", uint256(destConfig.chainSelector)));
        require(chainSelector != 0, "Chain selector is not defined for the destination chain. Set DEST_CHAIN_SELECTOR.");
        dest.chainSelector = chainSelector;

        // Resolve human-readable destination chain name for logs.
        dest.displayName = bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;

        // Resolve destination pool and token address strings.
        // For EVM: fall back to HelperConfig address lookup; convert address → string for uniform handling.
        // For non-EVM: DEST_TOKEN_POOL / DEST_TOKEN must be set explicitly.
        if (isEvmDest) {
            // CLI override (DEST_TOKEN_POOL) takes priority over the chain-specific env var.
            address destPoolAddr = vm.envOr(
                "DEST_TOKEN_POOL",
                helperConfig.getDeployedTokenPool(helperConfig.parseChainName(destConfig.chainNameIdentifier))
            );
            require(
                destPoolAddr != address(0),
                string.concat(
                    "Token pool not deployed on destination chain. Set DEST_TOKEN_POOL or ",
                    destChainName,
                    "_TOKEN_POOL environment variable."
                )
            );
            address destTokenAddr = vm.envOr(
                "DEST_TOKEN", helperConfig.getDeployedToken(helperConfig.parseChainName(destConfig.chainNameIdentifier))
            );
            require(
                destTokenAddr != address(0),
                string.concat(
                    "Token not deployed on destination chain. Set DEST_TOKEN or ",
                    destChainName,
                    "_TOKEN environment variable."
                )
            );
            dest.rawPoolAddress = vm.toString(destPoolAddr);
            dest.rawTokenAddress = vm.toString(destTokenAddr);
        } else {
            // DEST_TOKEN_POOL takes priority; fall back to <DEST_CHAIN>_TOKEN_POOL (e.g. SOLANA_DEVNET_TOKEN_POOL).
            string memory chainSpecificPool = vm.envOr(string.concat(destChainName, "_TOKEN_POOL"), string(""));
            dest.rawPoolAddress = vm.envOr("DEST_TOKEN_POOL", chainSpecificPool);
            require(
                bytes(dest.rawPoolAddress).length > 0,
                string.concat("Destination pool not set. Set DEST_TOKEN_POOL or ", destChainName, "_TOKEN_POOL.")
            );

            // DEST_TOKEN takes priority; fall back to <DEST_CHAIN>_TOKEN (e.g. SOLANA_DEVNET_TOKEN).
            string memory chainSpecificToken = vm.envOr(string.concat(destChainName, "_TOKEN"), string(""));
            dest.rawTokenAddress = vm.envOr("DEST_TOKEN", chainSpecificToken);
            require(
                bytes(dest.rawTokenAddress).length > 0,
                string.concat("Destination token not set. Set DEST_TOKEN or ", destChainName, "_TOKEN.")
            );
        }

        // Validate addresses for their destination chain family.
        require(
            ChainHandlers.validateChainAddress(dest.rawPoolAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " pool address: ", dest.rawPoolAddress)
        );
        require(
            ChainHandlers.validateChainAddress(dest.rawTokenAddress, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " token address: ", dest.rawTokenAddress)
        );

        // Encode addresses for the destination chain family.
        // EVM:   abi.encode(address)  — 32-byte ABI-padded word
        // SVM:   raw 32 bytes          — base58-decoded Solana public key
        dest.poolEncoded = ChainHandlers.prepareChainAddressData(dest.rawPoolAddress, destChainFamily);
        dest.tokenEncoded = ChainHandlers.prepareChainAddressData(dest.rawTokenAddress, destChainFamily);
    }

    /// @dev Builds the ChainUpdate payload and calls applyChainUpdates on the pool.
    ///      Extracted from _runFromEnv() to keep its stack depth within the EVM's 16-slot limit.
    function _applyChainUpdateToPool(
        address poolAddress,
        DestChainParams memory dest,
        RateLimiter.Config memory outboundRateLimiterConfig,
        RateLimiter.Config memory inboundRateLimiterConfig
    ) internal {
        // Instantiate the source TokenPool contract
        TokenPool poolContract = TokenPool(poolAddress);

        // Pool address encoded per destination chain family
        bytes[] memory destPoolAddressesEncoded = new bytes[](1);
        destPoolAddressesEncoded[0] = dest.poolEncoded;

        // Idempotent: remove existing config for dest chain before applying new one
        bool chainAlreadyConfigured = poolContract.isSupportedChain(dest.chainSelector);
        uint64[] memory chainSelectorRemovals = chainAlreadyConfigured ? new uint64[](1) : new uint64[](0);
        if (chainAlreadyConfigured) {
            chainSelectorRemovals[0] = dest.chainSelector;
            console.log(unicode"⚠️  Existing config detected for destination chain selector; replacing it.");
        } else {
            console.log("No existing config for destination chain selector; adding new one.");
        }

        // Prepare chain update data
        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](1);
        chainUpdates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: dest.chainSelector,
            remotePoolAddresses: destPoolAddressesEncoded,
            remoteTokenAddress: dest.tokenEncoded,
            outboundRateLimiterConfig: outboundRateLimiterConfig,
            inboundRateLimiterConfig: inboundRateLimiterConfig
        });

        // Apply the chain updates through the shared action layer.
        (PoolVersions.Version poolVersion, string memory poolTypeAndVersion) = PoolVersion.resolve(poolAddress);
        console.log(string.concat("Pool contract: ", poolTypeAndVersion));
        bool[] memory replaceExisting = new bool[](1);
        replaceExisting[0] = chainAlreadyConfigured;
        executeCalls(
            _buildLaneUpdateCalls(poolVersion, poolAddress, chainSelectorRemovals, chainUpdates, replaceExisting)
        );
        console.log(unicode"✅ Chain updates applied successfully!");
    }

    /// @dev The exhaustive version switch of the lane-update dispatch: 1.5.0 takes the
    ///      single-argument encoding, every later cataloged version takes the modern
    ///      (removes[], adds[]) encoding. `PoolVersion.resolve` refuses uncataloged versions before
    ///      this switch runs, and a version added to the catalog without a branch here fails loudly
    ///      instead of falling through to the modern encoding.
    function _buildLaneUpdateCalls(
        PoolVersions.Version version,
        address poolAddress,
        uint64[] memory chainSelectorRemovals,
        TokenPool.ChainUpdate[] memory chainUpdates,
        bool[] memory replaceExisting
    ) internal pure returns (CctActions.Call[] memory) {
        if (version == PoolVersions.Version.V1_5_0) {
            console.log("Pool contract version 1.5.0 detected; using the 1.5.0 lane-update encoding.");
            return CctActions.applyChainUpdatesV150(poolAddress, _toV150Updates(chainUpdates, replaceExisting));
        }
        if (
            version == PoolVersions.Version.V1_5_1 || version == PoolVersions.Version.V1_6_1
                || version == PoolVersions.Version.V2_0_0
        ) {
            return CctActions.applyChainUpdates(poolAddress, chainSelectorRemovals, chainUpdates);
        }
        revert(
            "ApplyChainUpdates: pool version has no lane-update dispatch branch; extend the switch here and the catalog in src/PoolVersions.sol"
        );
    }

    /// @dev Converts modern `ChainUpdate` entries to the 1.5.0 shape. A replaced lane becomes an
    ///      `allowed: false` entry (disabled rate limits, per the 1.5.0 validation rules) followed by
    ///      its `allowed: true` entry; 1.5.0 processes the array in order, so the pair is one atomic
    ///      replacement. 1.5.0 supports exactly one remote pool address per chain.
    function _toV150Updates(TokenPool.ChainUpdate[] memory updates, bool[] memory replaceExisting)
        internal
        pure
        returns (ITokenPoolV150.ChainUpdate[] memory out)
    {
        uint256 count = updates.length;
        for (uint256 i = 0; i < replaceExisting.length; i++) {
            if (replaceExisting[i]) count++;
        }
        out = new ITokenPoolV150.ChainUpdate[](count);
        uint256 k = 0;
        for (uint256 i = 0; i < updates.length; i++) {
            require(
                updates[i].remotePoolAddresses.length == 1,
                string.concat(
                    "Pool contract version 1.5.0 supports exactly one remote pool per chain; got ",
                    vm.toString(updates[i].remotePoolAddresses.length),
                    " for selector ",
                    vm.toString(updates[i].remoteChainSelector)
                )
            );
            if (replaceExisting[i]) {
                out[k++] = ITokenPoolV150.ChainUpdate({
                    remoteChainSelector: updates[i].remoteChainSelector,
                    allowed: false,
                    remotePoolAddress: "",
                    remoteTokenAddress: "",
                    outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
                    inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
                });
            }
            out[k++] = ITokenPoolV150.ChainUpdate({
                remoteChainSelector: updates[i].remoteChainSelector,
                allowed: true,
                remotePoolAddress: updates[i].remotePoolAddresses[0],
                remoteTokenAddress: updates[i].remoteTokenAddress,
                outboundRateLimiterConfig: updates[i].outboundRateLimiterConfig,
                inboundRateLimiterConfig: updates[i].inboundRateLimiterConfig
            });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rate-limit input resolution  — env > lanes{} > disabled default (CLI mode)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev How the CLI-mode rate-limit buckets were resolved, per direction, plus everything the
    ///      console (and the tests) need to explain the decision: which rung supplied each bucket,
    ///      which lanes{} entry matched, whether an env override diverges from the declared policy,
    ///      and the exact `make add-lane` command that would bring the declaration in line.
    struct RateLimitResolution {
        RateLimiter.Config outbound;
        RateLimiter.Config inbound;
        bool outboundFromEnv;
        bool inboundFromEnv;
        bool outboundFromLanes;
        bool inboundFromLanes;
        bool configFound; // config/chains/<configName>.json exists for the local chain
        string configName;
        DeclaredLane lane; // the matched lanes{} entry, when lane.found
        bool outboundDiverges; // env override differs from the declared outbound policy
        bool inboundDiverges; // env override differs from the declared inbound{} block
        bool addLaneHint; // an env-driven apply left the declaration missing or diverging
        string addLaneCommand; // the exact remediation command, with the values just applied
    }

    /// @dev One declared lanes{} entry, parsed with the same conventions as the doctor's lanes rung
    ///      (`VerifyChain._declaredBucket`): quoted-decimal uints read via `vm.parseJsonUint`, a
    ///      missing capacity/rate key reads as 0, and a bucket is enabled iff capacity or rate is
    ///      non-zero. An absent `inbound{}` block is undeclared, never defaulted.
    struct DeclaredLane {
        bool found;
        string key;
        uint256 capacity;
        uint256 rate;
        bool inboundDeclared;
        uint256 inboundCapacity;
        uint256 inboundRate;
    }

    /// @dev Resolves the CLI-mode rate-limit buckets through the two-rung input ladder, per
    ///      direction (see the contract natspec). lanes{} is OWNER INTENT: an env-driven apply
    ///      never writes it back — the `make add-lane` hint plus the doctor WARN close the loop
    ///      through a reviewed edit by design.
    function _resolveRateLimiterConfigs(string memory destChainName, uint64 destChainSelector)
        internal
        view
        returns (RateLimitResolution memory res)
    {
        (res.outboundFromEnv, res.outbound) = _envBucket("OUTBOUND");
        (res.inboundFromEnv, res.inbound) = _envBucket("INBOUND");

        string memory json;
        (res.configFound, res.configName, json) = _findLocalChainConfig();
        if (res.configFound) res.lane = _findDeclaredLane(json, destChainName, destChainSelector);

        // Rung 2: a direction with no env vars takes the declared lanes{} policy. An absent
        // inbound{} block keeps the env-absent default (disabled), exactly as before.
        if (!res.outboundFromEnv && res.lane.found) {
            res.outboundFromLanes = true;
            res.outbound = _declaredConfig(res.lane.capacity, res.lane.rate);
        }
        if (!res.inboundFromEnv && res.lane.found && res.lane.inboundDeclared) {
            res.inboundFromLanes = true;
            res.inbound = _declaredConfig(res.lane.inboundCapacity, res.lane.inboundRate);
        }

        // Rung 1 cross-check: an env override that disagrees with the declared policy is a notice,
        // never a revert (the doctor WARNs until reconciled). An undeclared inbound{} block is not
        // compared — same absent-means-undeclared rule the doctor applies.
        if (res.lane.found && res.outboundFromEnv) {
            res.outboundDiverges = _diverges(res.outbound, res.lane.capacity, res.lane.rate);
        }
        if (res.lane.found && res.inboundFromEnv && res.lane.inboundDeclared) {
            res.inboundDiverges = _diverges(res.inbound, res.lane.inboundCapacity, res.lane.inboundRate);
        }

        if (
            (res.outboundFromEnv || res.inboundFromEnv) && res.configFound
                && (!res.lane.found || res.outboundDiverges || res.inboundDiverges)
        ) {
            res.addLaneHint = true;
            res.addLaneCommand = _composeAddLaneCommand(res, destChainName);
        }
    }

    /// @dev Reads one direction's rate-limit env vars — byte-for-byte the historical env behavior:
    ///      isEnabled defaults to true when CAPACITY or RATE is set, ENABLED overrides it
    ///      explicitly, and a disabled bucket zeroes its values. `provided` is true when ANY of the
    ///      direction's env vars is set (the rung-1 trigger).
    function _envBucket(string memory prefix) internal view returns (bool provided, RateLimiter.Config memory config) {
        string memory capacityVar = string.concat(prefix, "_RATE_LIMIT_CAPACITY");
        string memory rateVar = string.concat(prefix, "_RATE_LIMIT_RATE");
        string memory enabledVar = string.concat(prefix, "_RATE_LIMIT_ENABLED");

        bool valuesProvided = _rlEnvExists(capacityVar) || _rlEnvExists(rateVar);
        provided = valuesProvided || _rlEnvExists(enabledVar);
        bool enabled = _rlEnvBool(enabledVar, valuesProvided);
        config = RateLimiter.Config({
            isEnabled: enabled,
            capacity: enabled ? uint128(_rlEnvUint(capacityVar)) : 0,
            rate: enabled ? uint128(_rlEnvUint(rateVar)) : 0
        });
    }

    /// @dev A declared bucket as a RateLimiter.Config: enabled iff capacity or rate is non-zero —
    ///      the same inference the doctor's lanes rung uses (declared 0/0 is declared-disabled).
    function _declaredConfig(uint256 capacity, uint256 rate) internal pure returns (RateLimiter.Config memory) {
        bool enabled = capacity != 0 || rate != 0;
        return RateLimiter.Config({isEnabled: enabled, capacity: uint128(capacity), rate: uint128(rate)});
    }

    /// @dev Same agreement rule as the doctor's lanes rung (`VerifyChain._reconcileBucket`):
    ///      enabled states must match, and an enabled bucket must match on capacity and rate.
    function _diverges(RateLimiter.Config memory applied, uint256 declaredCapacity, uint256 declaredRate)
        internal
        pure
        returns (bool)
    {
        bool declaredEnabled = declaredCapacity != 0 || declaredRate != 0;
        if (applied.isEnabled != declaredEnabled) return true;
        return applied.isEnabled && (applied.capacity != declaredCapacity || applied.rate != declaredRate);
    }

    /// @dev The local chain's config file (matched on the declared `chainId` == block.chainid),
    ///      discovered the same way HelperConfig discovers chains: by scanning `config/chains/`.
    function _findLocalChainConfig() internal view returns (bool found, string memory name, string memory json) {
        string[] memory names = ChainConfig.names();
        for (uint256 i = 0; i < names.length; i++) {
            string memory path = string.concat(vm.projectRoot(), "/config/chains/", names[i], ".json");
            // A file deleted or half-written between the directory scan and the read (parallel
            // test suites clean up scratch configs) is skipped, never an aborted run. Cheatcodes
            // are external calls to the VM contract, so try/catch applies directly — no self-call
            // (forge rejects address(this) in script contracts at runtime).
            try vm.readFile(path) returns (string memory candidate) {
                try vm.parseJsonUint(candidate, ".chainId") returns (uint256 declaredChainId) {
                    if (declaredChainId == block.chainid) return (true, names[i], candidate);
                } catch {
                    continue;
                }
            } catch {
                continue;
            }
        }
        return (false, "", "");
    }

    /// @dev Finds the lanes{} entry for the destination in the local chain config. Match by remote
    ///      chain name first — a lanes key IS the remote's config file basename, and DEST_CHAIN may
    ///      carry either that basename or the remote's chainNameIdentifier — then fall back to
    ///      remoteSelector equality (the same join key the doctor's lanes rung reconciles on).
    function _findDeclaredLane(string memory json, string memory destChainName, uint64 destChainSelector)
        internal
        view
        returns (DeclaredLane memory lane)
    {
        if (!vm.keyExistsJson(json, ".lanes")) return lane;
        string[] memory keys = vm.parseJsonKeys(json, ".lanes");

        for (uint256 i = 0; i < keys.length && !lane.found; i++) {
            if (_sameString(keys[i], destChainName)) _readDeclaredLane(json, keys[i], lane);
        }
        for (uint256 i = 0; i < keys.length && !lane.found; i++) {
            (bool ok, ChainConfig.Chain memory c,) = ChainConfig.tryLoad(keys[i]);
            if (ok && _sameString(c.chainNameIdentifier, destChainName)) _readDeclaredLane(json, keys[i], lane);
        }
        for (uint256 i = 0; i < keys.length && !lane.found; i++) {
            string memory selectorKey = string.concat(".lanes.", keys[i], ".remoteSelector");
            if (vm.keyExistsJson(json, selectorKey) && vm.parseJsonUint(json, selectorKey) == destChainSelector) {
                _readDeclaredLane(json, keys[i], lane);
            }
        }
    }

    /// @dev Parses one matched lanes{} entry into `lane` (see the DeclaredLane parsing conventions).
    function _readDeclaredLane(string memory json, string memory key, DeclaredLane memory lane) internal view {
        lane.found = true;
        lane.key = key;
        string memory lanePath = string.concat(".lanes.", key);
        (lane.capacity, lane.rate) = _declaredBucket(json, lanePath);
        if (vm.keyExistsJson(json, string.concat(lanePath, ".inbound"))) {
            lane.inboundDeclared = true;
            (lane.inboundCapacity, lane.inboundRate) = _declaredBucket(json, string.concat(lanePath, ".inbound"));
        }
    }

    /// @dev Declared (capacity, rate) at `declPath`; a missing key reads as 0. Duplicated from the
    ///      doctor's lanes rung (`VerifyChain._declaredBucket`) so both consumers parse identically.
    function _declaredBucket(string memory json, string memory declPath)
        internal
        view
        returns (uint256 capacity, uint256 rate)
    {
        string memory capacityKey = string.concat(declPath, ".capacity");
        string memory rateKey = string.concat(declPath, ".rate");
        capacity = vm.keyExistsJson(json, capacityKey) ? vm.parseJsonUint(json, capacityKey) : 0;
        rate = vm.keyExistsJson(json, rateKey) ? vm.parseJsonUint(json, rateKey) : 0;
    }

    /// @dev The exact `make add-lane` remediation command carrying the values just applied. The
    ///      INBOUND pair is included iff the applied inbound bucket is enabled.
    function _composeAddLaneCommand(RateLimitResolution memory res, string memory destChainName)
        internal
        view
        returns (string memory cmd)
    {
        string memory remote = res.lane.found ? res.lane.key : _remoteConfigName(destChainName);
        cmd = string.concat(
            "make add-lane LOCAL=",
            res.configName,
            " REMOTE=",
            remote,
            " CAPACITY=",
            vm.toString(uint256(res.outbound.capacity)),
            " RATE=",
            vm.toString(uint256(res.outbound.rate))
        );
        if (res.inbound.isEnabled) {
            cmd = string.concat(
                cmd,
                " INBOUND_CAPACITY=",
                vm.toString(uint256(res.inbound.capacity)),
                " INBOUND_RATE=",
                vm.toString(uint256(res.inbound.rate))
            );
        }
    }

    /// @dev The destination's config file basename for the hint: the DEST_CHAIN value itself when a
    ///      config file of that name exists, otherwise the file whose chainNameIdentifier matches;
    ///      falls back to the raw DEST_CHAIN value when the remote has no config file yet.
    function _remoteConfigName(string memory destChainName) internal view returns (string memory) {
        string[] memory names = ChainConfig.names();
        for (uint256 i = 0; i < names.length; i++) {
            if (_sameString(names[i], destChainName)) return names[i];
        }
        for (uint256 i = 0; i < names.length; i++) {
            (bool ok, ChainConfig.Chain memory c,) = ChainConfig.tryLoad(names[i]);
            if (ok && _sameString(c.chainNameIdentifier, destChainName)) return names[i];
        }
        return destChainName;
    }

    /// @dev The resolution-ladder console lines: which rung supplied the buckets, and the
    ///      per-direction divergence notice (a notice, not a revert) naming both values and the
    ///      lane entry.
    function _logRateLimitResolution(RateLimitResolution memory res, string memory destChainName) internal pure {
        if (res.outboundFromLanes || res.inboundFromLanes) {
            console.log(
                string.concat(
                    "  Rate limits resolved from lanes.",
                    res.lane.key,
                    " in config/chains/",
                    res.configName,
                    ".json (",
                    res.outboundFromLanes ? (res.inboundFromLanes ? "outbound + inbound" : "outbound") : "inbound",
                    ")"
                )
            );
        }
        if (!res.outboundFromEnv && !res.inboundFromEnv && !res.lane.found) {
            console.log(
                string.concat(
                    "  No rate-limit env vars and no lanes{} entry for ",
                    destChainName,
                    res.configFound ? string.concat(" in config/chains/", res.configName, ".json") : "",
                    "; rate limiting disabled (default). Set the env vars, or declare the lane: make add-lane"
                )
            );
        }
        if (res.outboundDiverges) {
            console.log(_divergenceNotice("OUTBOUND", res.outbound, res.lane.capacity, res.lane.rate, res));
        }
        if (res.inboundDiverges) {
            console.log(_divergenceNotice("INBOUND", res.inbound, res.lane.inboundCapacity, res.lane.inboundRate, res));
        }
    }

    /// @dev One divergence-notice line for one direction, naming the applied env values, the
    ///      declared lanes{} values, and the lane entry.
    function _divergenceNotice(
        string memory direction,
        RateLimiter.Config memory applied,
        uint256 declaredCapacity,
        uint256 declaredRate,
        RateLimitResolution memory res
    ) internal pure returns (string memory) {
        return string.concat(
            unicode"  ⚠️  ",
            direction,
            " rate-limit env override (enabled=",
            vm.toString(applied.isEnabled),
            " capacity=",
            vm.toString(uint256(applied.capacity)),
            " rate=",
            vm.toString(uint256(applied.rate)),
            ") diverges from declared lanes.",
            res.lane.key,
            " (capacity=",
            vm.toString(declaredCapacity),
            " rate=",
            vm.toString(declaredRate),
            ") in config/chains/",
            res.configName,
            ".json - make doctor will WARN until reconciled"
        );
    }

    /// @dev The closing remediation hint. lanes{} is owner intent — applies never auto-write it;
    ///      this hint plus the doctor WARN close the loop through a reviewed edit by design. Note
    ///      `make add-lane` skips an EXISTING entry (duplicate = byte-identical no-op), so the
    ///      divergence variant names the hand edit first.
    function _logAddLaneHint(RateLimitResolution memory res) internal pure {
        if (!res.addLaneHint) return;
        if (res.lane.found) {
            console.log(
                string.concat(
                    unicode"⚠️  Applied rate limits diverge from declared lanes.",
                    res.lane.key,
                    " in config/chains/",
                    res.configName,
                    ".json. Reconcile the declaration: edit the entry to the applied values, or remove it and run: ",
                    res.addLaneCommand
                )
            );
        } else {
            console.log(
                string.concat(
                    unicode"⚠️  This lane is not declared in lanes{} (config/chains/",
                    res.configName,
                    ".json). Declare it: ",
                    res.addLaneCommand
                )
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Env-access seams
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Env-access seams for the rate-limit resolution ladder. Virtual so tests can inject
    ///      values without vm.setEnv (env vars are process-global and forge runs suites in
    ///      parallel); the default implementations preserve the original vm.envOr reads exactly.
    function _rlEnvExists(string memory name) internal view virtual returns (bool) {
        string memory sentinel = "__not_set__";
        return keccak256(bytes(vm.envOr(name, sentinel))) != keccak256(bytes(sentinel));
    }

    function _rlEnvUint(string memory name) internal view virtual returns (uint256) {
        return vm.envOr(name, uint256(0));
    }

    function _rlEnvBool(string memory name, bool defaultValue) internal view virtual returns (bool) {
        return vm.envOr(name, defaultValue);
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
