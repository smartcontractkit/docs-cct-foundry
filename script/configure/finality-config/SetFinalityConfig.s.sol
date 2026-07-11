// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {RateLimiterUtils, ITokenPoolV1RateLimiter} from "../../utils/RateLimiterUtils.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {FinalityConfigUtils} from "../../utils/FinalityConfigUtils.s.sol";
import {LanePolicySource} from "../../utils/LanePolicySource.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Sets the allowed finality configuration on a TokenPool, and optionally updates rate limits
/// for the fast finality bucket on a specific remote chain lane.
///
/// @dev This function is only available on TokenPool v2.0 and later.
/// The allowed finality config controls which fast finality modes are accepted for cross-chain transfers.
///
/// Exactly one finality mode must be specified (or none, to use WAIT_FOR_FINALITY as the default):
///   BLOCK_DEPTH=<n>                      — Allow fast finality after N block confirmations (1–65535).
///   WAIT_FOR_SAFE=true                   — Allow fast finality transfers using the `safe` head.
///   BLOCK_DEPTH=<n> + WAIT_FOR_SAFE=true — Allow both modes simultaneously (pool accepts either).
///   (neither)                            — WAIT_FOR_FINALITY (default): disables fast finality transfers.
///
/// Environment Variables (finality mode — any combination):
///   BLOCK_DEPTH    - uint16, number of block confirmations to allow (1–65535).
///   WAIT_FOR_SAFE  - true/false, set to true to also allow transfers using the `safe` head.
///
/// Environment Variables (optional — rate limiter):
///   DEST_CHAIN                    - Remote chain whose lane is queried/updated (e.g. MANTLE_SEPOLIA).
///                                   Required when any rate limit variable is set; if omitted the rate
///                                   limiter section is skipped entirely.
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, outbound token bucket capacity
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, outbound token bucket refill rate
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (defaults to true when CAPACITY or RATE are set)
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, inbound token bucket capacity
///   INBOUND_RATE_LIMIT_RATE       - uint128, inbound token bucket refill rate
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (defaults to true when CAPACITY or RATE are set)
///
/// Behaviour (rate limiter section):
///   * DEST_CHAIN only               -> logs current rate limits for the fast finality bucket
///   * DEST_CHAIN + rate limit vars  -> logs current, applies updates, logs updated state
///   * Rate limit vars without DEST_CHAIN -> reverts with a helpful error
///
/// @dev The fast-finality rate-limit update here is the ENV-OVERRIDE path only: it fires solely when
///      the OUTBOUND_*/INBOUND_* env vars are set, and it never sources buckets from `lanes{}`. When
///      an env-applied bucket CONTRADICTS a declared `lanes.<remote>.v2.fastFinality.<dir>` policy,
///      the script prints the same one-line divergence notice and closing hand-edit hint
///      `UpdateRateLimiters` prints (`make doctor` WARNs until reconciled); an absent or agreeing
///      declaration is silent. To DECLARE the fast-finality policy and apply it from `lanes{}`, use
///      `UpdateRateLimiters` with `FAST_FINALITY=true` (the declare-from-policy path).
///
/// Usage examples:
///   # Set block depth and configure the fast finality rate limit bucket:
///   BLOCK_DEPTH=5 DEST_CHAIN=MANTLE_SEPOLIA \
///   OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Set block depth only (no rate limit changes):
///   BLOCK_DEPTH=5 \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Use WAIT_FOR_SAFE mode and view current rate limits for a lane (no update):
///   WAIT_FOR_SAFE=true DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Reset to default finality (disables fast finality transfers):
///   forge script script/configure/finality-config/SetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetFinalityConfig is EoaExecutor, LanePolicySource {
    HelperConfig public helperConfig;

    // ── Storage: avoids EVM stack pressure inside run() ────────────────────
    bytes4 private s_newFinalityConfig;
    // The composed closing hand-edit hints for an env-applied fast-finality bucket that diverges
    // from a declared lanes{}.v2.fastFinality policy; printed after the footer (empty when none).
    string private s_ffOutboundHint;
    string private s_ffInboundHint;

    /// @dev The fast-finality rate-limit divergence resolution: whether an env-applied bucket
    ///      contradicts a declared `lanes.<remote>.v2.fastFinality.<dir>` policy, plus the composed
    ///      notice/hint strings (pinned byte-exact by the test). Fires only on declared-and-diverges;
    ///      an absent or agreeing declaration leaves every flag/string empty.
    struct FastFinalityRlDivergence {
        bool configFound;
        string configName;
        bool laneFound;
        string laneKey;
        bool outboundDeclared;
        uint256 outboundDeclCapacity;
        uint256 outboundDeclRate;
        bool inboundDeclared;
        uint256 inboundDeclCapacity;
        uint256 inboundDeclRate;
        bool outboundDiverges;
        bool inboundDiverges;
        bool editHint;
        string outboundNotice;
        string inboundNotice;
        string outboundHint;
        string inboundHint;
    }

    function run() external {
        // ── Build and validate finality config ────────────────────────────
        s_newFinalityConfig = _buildFinalityConfig();

        // ── Optional env vars — rate limiter ───────────────────────────────
        string memory sentinel = "__not_set__";
        bool destChainSet = keccak256(bytes(vm.envOr("DEST_CHAIN", sentinel))) != keccak256(bytes(sentinel));
        string memory destChainName = destChainSet ? vm.envString("DEST_CHAIN") : "";

        RateLimiterUtils.RateLimitUpdate memory update = RateLimiterUtils.readRateLimitUpdate();
        bool hasRateLimitUpdate = update.updateOutbound || update.updateInbound;

        require(
            !hasRateLimitUpdate || destChainSet,
            "DEST_CHAIN must be set when specifying rate limit environment variables"
        );

        // ── Resolve chain ID ──────────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // ── Version fence ──────────────────────────────────────────────────
        // setAllowedFinalityConfig (below) is a v2-only setter, and it runs on EVERY invocation
        // (not only when DEST_CHAIN is set). Resolve the pool's on-chain contract version
        // unconditionally and refuse by name before the write; the rate-limit path reuses this
        // version. This script broadcasts, so use resolve (refuses uncataloged/-dev pools).
        (PoolVersions.Version poolVersion,) = PoolVersion.resolve(tokenPoolAddress);
        PoolVersions.requireSupports(PoolVersions.Op.SET_ALLOWED_FINALITY_CONFIG, poolVersion, tokenPoolAddress);

        // ── Resolve remote chain (only when DEST_CHAIN is set) ─────────────
        uint64 remoteChainSelector;
        string memory destChainFullName;
        if (destChainSet) {
            uint256 destChainId = helperConfig.parseChainName(destChainName);
            remoteChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;
            destChainFullName = helperConfig.getChainName(destChainId);
        }

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⏱️  Set Finality Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        if (destChainSet) {
            console.log(string.concat("Remote Chain: ", destChainFullName));
        }
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Set finality config"));
        console.log("========================================");
        console.log("");

        // ── Show current and new finality config ───────────────────────────
        _logCurrentConfig(tokenPool);
        console.log(
            string.concat("  New Finality Config:          ", vm.toString(abi.encodePacked(s_newFinalityConfig)))
        );
        console.log(
            string.concat("  Mode:                         ", FinalityConfigUtils.decodeModeLabel(s_newFinalityConfig))
        );
        console.log("");

        // ── Log current rate limits (if DEST_CHAIN provided) ──────────────
        if (destChainSet) {
            console.log("----------------------------------------");
            console.log(unicode"📊 Current Rate Limits (fast finality where enabled, standard otherwise):");
            console.log("----------------------------------------");
            RateLimiterUtils.logRateLimiterStateWithFallback(
                tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, poolVersion
            );
        }

        // ── Step 1: Set finality config ────────────────────────────────────
        console.log(string.concat("[Step 1] Setting finality config on ", chainName));

        executeCalls(CctActions.setAllowedFinalityConfig(tokenPoolAddress, s_newFinalityConfig));
        console.log(unicode"✅ Finality config set successfully!");

        // ── Step 2: Apply rate limit update (if requested) ─────────────────
        if (hasRateLimitUpdate) {
            _applyRateLimitUpdate(
                tokenPool,
                tokenPoolAddress,
                remoteChainSelector,
                destChainName,
                destChainFullName,
                chainName,
                update,
                poolVersion
            );
        }

        // ── Log updated rate limits (if DEST_CHAIN provided) ──────────────
        if (destChainSet) {
            console.log("");
            console.log("----------------------------------------");
            console.log(unicode"📊 Updated Rate Limits (fast finality where enabled, standard otherwise):");
            console.log("----------------------------------------");
            RateLimiterUtils.logRateLimiterStateWithFallback(
                tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, poolVersion
            );
        }

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Configuration Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Finality Config: ", vm.toString(abi.encodePacked(s_newFinalityConfig))));
        console.log(string.concat("Mode:            ", FinalityConfigUtils.decodeModeLabel(s_newFinalityConfig)));
        console.log(
            string.concat("Token Pool:      ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        // Closing hand-edit hints for an env-applied fast-finality bucket that diverges from a
        // declared lanes{}.v2.fastFinality policy (empty unless it fired).
        if (bytes(s_ffOutboundHint).length != 0) console.log(s_ffOutboundHint);
        if (bytes(s_ffInboundHint).length != 0) console.log(s_ffInboundHint);
        console.log("");
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Reads BLOCK_DEPTH / WAIT_FOR_SAFE env vars, validates them, and encodes the bytes4 config.
    /// Extracted into its own function to keep the EVM stack depth of run() within the 16-slot limit.
    function _buildFinalityConfig() internal view returns (bytes4) {
        bool waitForSafe = vm.envOr("WAIT_FOR_SAFE", false);
        uint256 blockDepthRaw = vm.envOr("BLOCK_DEPTH", uint256(0));

        require(blockDepthRaw <= FinalityCodec.MAX_BLOCK_DEPTH, "BLOCK_DEPTH must be <= FinalityCodec.MAX_BLOCK_DEPTH");

        if (waitForSafe && blockDepthRaw > 0) return FinalityCodec._encodeBlockDepthAndSafeFlag(uint16(blockDepthRaw));
        if (waitForSafe) return FinalityCodec.WAIT_FOR_SAFE_FLAG;
        if (blockDepthRaw > 0) return FinalityCodec._encodeBlockDepth(uint16(blockDepthRaw));
        return FinalityCodec.WAIT_FOR_FINALITY_FLAG;
    }

    /// @dev Logs the current on-chain finality config. Isolated to avoid stack depth pressure in run().
    function _logCurrentConfig(TokenPool tokenPool) internal view {
        try tokenPool.getAllowedFinalityConfig() returns (bytes4 currentFinality) {
            console.log(
                string.concat("  Current Finality Config:      ", vm.toString(abi.encodePacked(currentFinality)))
            );
        } catch {
            console.log(string.concat("  Current Finality Config:      ", "Not available (pool version < 2.0)"));
        }
    }

    /// @dev Applies a rate limit update to the fast finality bucket. Isolated to reduce run() stack depth.
    function _applyRateLimitUpdate(
        TokenPool tokenPool,
        address tokenPoolAddress,
        uint64 remoteChainSelector,
        string memory destChainName,
        string memory destChainFullName,
        string memory chainName,
        RateLimiterUtils.RateLimitUpdate memory u,
        PoolVersions.Version poolVersion
    ) internal {
        console.log("");
        console.log(
            string.concat(
                "[Step 2] Updating rate limits (fast finality bucket) on ", chainName, " -> ", destChainFullName
            )
        );

        (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) = RateLimiterUtils.getCurrentConfigs(
            tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, true, poolVersion
        );

        if (u.updateOutbound) {
            outbound = RateLimiter.Config({
                isEnabled: u.outboundEnabled,
                capacity: u.outboundEnabled ? u.outboundCapacity : 0,
                rate: u.outboundEnabled ? u.outboundRate : 0
            });
        }
        if (u.updateInbound) {
            inbound = RateLimiter.Config({
                isEnabled: u.inboundEnabled,
                capacity: u.inboundEnabled ? u.inboundCapacity : 0,
                rate: u.inboundEnabled ? u.inboundRate : 0
            });
        }

        RateLimiterUtils.logNewConfig(u.updateOutbound, outbound, u.updateInbound, inbound);

        // Fast-finality bucket update (fastFinality=true) through the version-dispatched action layer.
        // setAllowedFinalityConfig above already established this is a v2 pool.
        executeCalls(
            CctActions.setRateLimits(address(tokenPool), poolVersion, remoteChainSelector, true, outbound, inbound)
        );

        console.log(unicode"✅ Rate limits updated successfully!");

        // Reconcile the applied (env-override) fast-finality buckets against the declared
        // lanes{}.v2.fastFinality policy: print the divergence notice inline, store the closing hint.
        _reconcileFastFinality(outbound, u.updateOutbound, inbound, u.updateInbound, destChainName, remoteChainSelector);
    }

    /// @dev Computes the fast-finality divergence, prints the per-direction divergence notice, and
    ///      stores the closing hand-edit hint (printed after the footer). Env-override path only:
    ///      fires solely when an applied direction contradicts a declared fast-finality bucket.
    function _reconcileFastFinality(
        RateLimiter.Config memory outbound,
        bool updateOutbound,
        RateLimiter.Config memory inbound,
        bool updateInbound,
        string memory destChainName,
        uint64 destChainSelector
    ) internal {
        FastFinalityRlDivergence memory res = _resolveFastFinalityDivergence(
            outbound, updateOutbound, inbound, updateInbound, destChainName, destChainSelector
        );
        if (res.outboundDiverges) console.log(res.outboundNotice);
        if (res.inboundDiverges) console.log(res.inboundNotice);
        s_ffOutboundHint = res.outboundHint;
        s_ffInboundHint = res.inboundHint;
    }

    /// @dev The fast-finality divergence resolution (see FastFinalityRlDivergence). An env-applied
    ///      direction that CONTRADICTS a declared `lanes.<remote>.v2.fastFinality.<dir>` bucket flags
    ///      a divergence and composes the notice + hint (byte-exact the wording `UpdateRateLimiters`
    ///      prints); an absent or agreeing declaration is silent. No rung-2 sourcing: this never
    ///      supplies a bucket from lanes{}, it only reconciles what the env override applied.
    function _resolveFastFinalityDivergence(
        RateLimiter.Config memory outbound,
        bool updateOutbound,
        RateLimiter.Config memory inbound,
        bool updateInbound,
        string memory destChainName,
        uint64 destChainSelector
    ) internal view returns (FastFinalityRlDivergence memory res) {
        string memory json;
        (res.configFound, res.configName, json) = _findLocalChainConfig();
        if (res.configFound) (res.laneFound, res.laneKey) = _findLaneKey(json, destChainName, destChainSelector);
        if (!res.laneFound) {
            res.laneKey = _remoteConfigName(destChainName);
            return res;
        }

        string memory ftfPath = string.concat(".lanes.", res.laneKey, ".v2.fastFinality");
        if (vm.keyExistsJson(json, string.concat(ftfPath, ".outbound"))) {
            res.outboundDeclared = true;
            (res.outboundDeclCapacity, res.outboundDeclRate) =
                _declaredBucket(json, string.concat(ftfPath, ".outbound"));
        }
        if (vm.keyExistsJson(json, string.concat(ftfPath, ".inbound"))) {
            res.inboundDeclared = true;
            (res.inboundDeclCapacity, res.inboundDeclRate) = _declaredBucket(json, string.concat(ftfPath, ".inbound"));
        }

        if (updateOutbound && res.outboundDeclared) {
            res.outboundDiverges = _bucketDiverges(outbound, res.outboundDeclCapacity, res.outboundDeclRate);
        }
        if (updateInbound && res.inboundDeclared) {
            res.inboundDiverges = _bucketDiverges(inbound, res.inboundDeclCapacity, res.inboundDeclRate);
        }
        res.editHint = res.outboundDiverges || res.inboundDiverges;

        if (res.outboundDiverges) {
            res.outboundNotice = _composeFfDivergence(res, outbound, false);
            res.outboundHint = _composeFfEditHint(res, outbound, false);
        }
        if (res.inboundDiverges) {
            res.inboundNotice = _composeFfDivergence(res, inbound, true);
            res.inboundHint = _composeFfEditHint(res, inbound, true);
        }
    }

    /// @dev One divergence-notice line (byte-exact the wording UpdateRateLimiters' fast-finality
    ///      notice prints), returned so the test can pin it.
    function _composeFfDivergence(FastFinalityRlDivergence memory res, RateLimiter.Config memory applied, bool inbound)
        internal
        pure
        returns (string memory)
    {
        (uint256 declCapacity, uint256 declRate) =
            inbound ? (res.inboundDeclCapacity, res.inboundDeclRate) : (res.outboundDeclCapacity, res.outboundDeclRate);
        return string.concat(
            unicode"⚠️  ",
            inbound ? "INBOUND" : "OUTBOUND",
            " rate-limit env override (enabled=",
            vm.toString(applied.isEnabled),
            " capacity=",
            vm.toString(uint256(applied.capacity)),
            " rate=",
            vm.toString(uint256(applied.rate)),
            ") diverges from declared lanes.",
            res.laneKey,
            ".v2.fastFinality.",
            inbound ? "inbound" : "outbound",
            " (capacity=",
            vm.toString(declCapacity),
            " rate=",
            vm.toString(declRate),
            ") in config/chains/",
            res.configName,
            ".json - make doctor will WARN until reconciled"
        );
    }

    /// @dev One closing hand-edit hint line (byte-exact the wording UpdateRateLimiters' fast-finality
    ///      hint prints for a diverging bucket), returned so the test can pin it.
    function _composeFfEditHint(FastFinalityRlDivergence memory res, RateLimiter.Config memory applied, bool inbound)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            unicode"⚠️  Applied ",
            inbound ? "INBOUND" : "OUTBOUND",
            " values are diverging from lanes.",
            res.laneKey,
            ".v2.fastFinality.",
            inbound ? "inbound" : "outbound",
            " (config/chains/",
            res.configName,
            ".json). Hand-edit the entry to capacity=",
            vm.toString(uint256(applied.capacity)),
            " rate=",
            vm.toString(uint256(applied.rate)),
            " - make doctor CHAIN=",
            res.configName,
            " WARNs until reconciled"
        );
    }
}
