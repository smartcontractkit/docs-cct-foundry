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
import {ProjectStore} from "../../../src/utils/ProjectStore.sol";

/// @notice Sets the allowed finality configuration on a TokenPool, and optionally updates rate limits
/// for the fast finality bucket on a specific remote chain lane.
///
/// @dev This function is only available on TokenPool v2.0 and later.
/// The allowed finality config controls which fast finality modes are accepted for cross-chain transfers.
///
/// Finality modes (encoded into the bytes4 by FinalityConfigUtils._encode):
///   BLOCK_DEPTH=<n>                      - Allow fast finality after N block confirmations (1–65535).
///   WAIT_FOR_SAFE=true                   - Allow fast finality transfers using the `safe` head.
///   BLOCK_DEPTH=<n> + WAIT_FOR_SAFE=true - Allow both modes simultaneously (pool accepts either).
///   (neither)                            - WAIT_FOR_FINALITY (default): disables fast finality transfers.
///
/// Environment Variables (finality mode - any combination):
///   BLOCK_DEPTH    - uint16, number of block confirmations to allow (1–65535).
///   WAIT_FOR_SAFE  - true/false, set to true to also allow transfers using the `safe` head.
///
/// Ladder (the applied bytes4): env (either variable present, even explicitly false/0) > the
/// declared `poolPolicy.finality` block in the project store ({blockDepth?, waitForSafe?}; an empty
/// block declares the WAIT_FOR_FINALITY default) > WAIT_FOR_FINALITY (reset). An env value that
/// diverges from a declaration prints a one-line notice and a closing hand-edit hint, and
/// `make doctor` FAILs until reconciled (`poolPolicy` has no flag surface - reconcile by a reviewed
/// hand edit). The declaration is owner intent: an env-driven apply never writes it back.
///
/// Environment Variables (optional - rate limiter):
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
///      `UpdateRateLimiters` prints (`make doctor` FAILs until reconciled); an absent or agreeing
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
    // The composed closing hand-edit hint for an env-applied finality config that diverges from (or
    // is missing in) a declared poolPolicy.finality block; printed after the footer (empty when none).
    string private s_finalityHint;

    /// @dev How the applied finality config was resolved through the input ladder (env > declared
    ///      `poolPolicy.finality` > the WAIT_FOR_FINALITY reset), plus the composed divergence
    ///      notice/hint strings (pinned byte-exact by the test). The notice fires only on
    ///      declared-and-diverges; the hint also fires for an env apply with no declaration.
    struct FinalityResolution {
        bool fromEnv; // rung 1: WAIT_FOR_SAFE or BLOCK_DEPTH exists in the env
        bool fromDeclared; // rung 2: no env; poolPolicy.finality present
        bool declared; // poolPolicy.finality exists in the project store
        bytes4 declaredValue;
        bool configFound;
        string configName;
        bool diverges; // env value != declared value
        bytes4 value; // the resolved bytes4 that will be applied
        string notice;
        string hint;
    }

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
        // ── Resolve the finality config through the input ladder ───────────
        FinalityResolution memory finalityRes = _resolveFinality();
        s_newFinalityConfig = finalityRes.value;
        if (finalityRes.fromDeclared) {
            console.log(
                string.concat(
                    "Finality config resolved from poolPolicy.finality in ",
                    ProjectStore._display(finalityRes.configName)
                )
            );
        }
        if (finalityRes.diverges) console.log(finalityRes.notice);
        s_finalityHint = finalityRes.hint;

        // ── Optional env vars - rate limiter ───────────────────────────────
        string memory sentinel = "__not_set__";
        bool destChainSet = keccak256(bytes(vm.envOr("DEST_CHAIN", sentinel))) != keccak256(bytes(sentinel));
        string memory destChainName = destChainSet ? vm.envString("DEST_CHAIN") : "";

        RateLimiterUtils.RateLimitUpdate memory update = RateLimiterUtils._readRateLimitUpdate();
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
        (PoolVersions.Version poolVersion,) = PoolVersion._resolve(tokenPoolAddress);
        PoolVersions._requireSupports(PoolVersions.Op.SET_ALLOWED_FINALITY_CONFIG, poolVersion, tokenPoolAddress);

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
            string.concat("  Mode:                         ", FinalityConfigUtils._decodeModeLabel(s_newFinalityConfig))
        );
        console.log("");

        // ── Log current rate limits (if DEST_CHAIN provided) ──────────────
        if (destChainSet) {
            console.log("----------------------------------------");
            console.log(unicode"📊 Current Rate Limits (fast finality where enabled, standard otherwise):");
            console.log("----------------------------------------");
            RateLimiterUtils._logRateLimiterStateWithFallback(
                tokenPool, ITokenPoolV1RateLimiter(tokenPoolAddress), remoteChainSelector, poolVersion
            );
        }

        // ── Step 1: Set finality config ────────────────────────────────────
        console.log(string.concat("[Step 1] Setting finality config on ", chainName));

        _executeCalls(CctActions._setAllowedFinalityConfig(tokenPoolAddress, s_newFinalityConfig));
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
            RateLimiterUtils._logRateLimiterStateWithFallback(
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
        console.log(string.concat("Mode:            ", FinalityConfigUtils._decodeModeLabel(s_newFinalityConfig)));
        console.log(
            string.concat("Token Pool:      ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        // Closing hand-edit hints: an env-applied finality config that a declared poolPolicy.finality
        // block does not match (or that no block declares), and an env-applied fast-finality bucket
        // that diverges from a declared lanes{}.v2.fastFinality policy (each empty unless it fired).
        if (bytes(s_finalityHint).length != 0) console.log(s_finalityHint);
        if (bytes(s_ffOutboundHint).length != 0) console.log(s_ffOutboundHint);
        if (bytes(s_ffInboundHint).length != 0) console.log(s_ffInboundHint);
        console.log("");
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Reads BLOCK_DEPTH / WAIT_FOR_SAFE env vars, validates them, and encodes the bytes4 config.
    /// Extracted into its own function to keep the EVM stack depth of run() within the 16-slot limit.
    function _buildFinalityConfig() internal view returns (bytes4) {
        bool waitForSafe = _envBool("WAIT_FOR_SAFE", false);
        uint256 blockDepthRaw = _envUint("BLOCK_DEPTH");

        require(blockDepthRaw <= FinalityCodec.MAX_BLOCK_DEPTH, "BLOCK_DEPTH must be <= FinalityCodec.MAX_BLOCK_DEPTH");

        return FinalityConfigUtils._encode(waitForSafe, blockDepthRaw);
    }

    /// @dev The finality-config input ladder: env (either variable present - explicit false/0 still
    ///      pins the env rung) > declared `poolPolicy.finality` > WAIT_FOR_FINALITY (reset). With an
    ///      absent declaration the result is bit-identical to the env-only behavior, so a project
    ///      store with no poolPolicy block changes nothing.
    function _resolveFinality() internal view returns (FinalityResolution memory res) {
        res.fromEnv = _envExists("WAIT_FOR_SAFE") || _envExists("BLOCK_DEPTH");
        (res.configFound, res.configName,) = _findLocalChainConfig();
        if (res.configFound) {
            string memory json = _localProjectJson(res.configName);
            res.declared = vm.keyExistsJson(json, ".poolPolicy.finality");
            if (res.declared) res.declaredValue = FinalityConfigUtils._parseDeclared(json, ".poolPolicy.finality");
        }
        if (res.fromEnv) {
            res.value = _buildFinalityConfig();
            res.diverges = res.declared && res.value != res.declaredValue;
        } else if (res.declared) {
            res.fromDeclared = true;
            res.value = res.declaredValue;
        } else {
            res.value = FinalityCodec.WAIT_FOR_FINALITY_FLAG;
        }
        if (res.diverges) res.notice = _composeFinalityNotice(res);
        if (res.fromEnv && res.configFound && (!res.declared || res.diverges)) {
            res.hint = _composeFinalityEditHint(res);
        }
    }

    /// @dev One divergence-notice line for an env-applied finality config that contradicts the
    ///      declared poolPolicy.finality block (both sides raw + decoded), returned so the test can
    ///      pin it byte-exact.
    function _composeFinalityNotice(FinalityResolution memory res) internal view returns (string memory) {
        return string.concat(
            unicode"⚠️  Finality env override ",
            vm.toString(abi.encodePacked(res.value)),
            " (",
            FinalityConfigUtils._decodeModeLabel(res.value),
            ") diverges from declared poolPolicy.finality ",
            vm.toString(abi.encodePacked(res.declaredValue)),
            " (",
            FinalityConfigUtils._decodeModeLabel(res.declaredValue),
            ") in ",
            ProjectStore._display(res.configName),
            " - make doctor will FAIL until reconciled"
        );
    }

    /// @dev One closing hand-edit hint line for an env-applied finality config the declaration does
    ///      not match (or that no block declares), returned so the test can pin it byte-exact. The
    ///      suggested edit is decoded from the applied bytes4 (depth = lower 16 bits, safe = bit 16).
    function _composeFinalityEditHint(FinalityResolution memory res) internal view returns (string memory) {
        uint16 depth = uint16(uint32(res.value & FinalityCodec.BLOCK_DEPTH_MASK));
        bool safe = (res.value & FinalityCodec.WAIT_FOR_SAFE_FLAG) != bytes4(0);
        return string.concat(
            unicode"⚠️  Applied finality config ",
            vm.toString(abi.encodePacked(res.value)),
            res.declared ? " is diverging from" : " is not declared as",
            " poolPolicy.finality (",
            ProjectStore._display(res.configName),
            "). Hand-edit the block to blockDepth=",
            vm.toString(depth),
            " waitForSafe=",
            safe ? "true" : "false",
            " - make doctor CHAIN=",
            res.configName,
            " FAILs until reconciled"
        );
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

        (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) = RateLimiterUtils._getCurrentConfigs(
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

        RateLimiterUtils._logNewConfig(u.updateOutbound, outbound, u.updateInbound, inbound);

        // Fast-finality bucket update (fastFinality=true) through the version-dispatched action layer.
        // setAllowedFinalityConfig above already established this is a v2 pool.
        _executeCalls(
            CctActions._setRateLimits(address(tokenPool), poolVersion, remoteChainSelector, true, outbound, inbound)
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
        // Chain existence + name from config/chains; the lanes{} policy from the project store.
        (res.configFound, res.configName,) = _findLocalChainConfig();
        string memory json = _localProjectJson(res.configName);
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
        view
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
            ") in ",
            ProjectStore._display(res.configName),
            " - make doctor will FAIL until reconciled"
        );
    }

    /// @dev One closing hand-edit hint line (byte-exact the wording UpdateRateLimiters' fast-finality
    ///      hint prints for a diverging bucket), returned so the test can pin it.
    function _composeFfEditHint(FastFinalityRlDivergence memory res, RateLimiter.Config memory applied, bool inbound)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            unicode"⚠️  Applied ",
            inbound ? "INBOUND" : "OUTBOUND",
            " values are diverging from lanes.",
            res.laneKey,
            ".v2.fastFinality.",
            inbound ? "inbound" : "outbound",
            " (",
            ProjectStore._display(res.configName),
            "). Hand-edit the entry to capacity=",
            vm.toString(uint256(applied.capacity)),
            " rate=",
            vm.toString(uint256(applied.rate)),
            " - make doctor CHAIN=",
            res.configName,
            " FAILs until reconciled"
        );
    }
}
