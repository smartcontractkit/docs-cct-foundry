// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {RateLimiterUtils, ITokenPoolV1RateLimiter} from "../../utils/RateLimiterUtils.s.sol";
import {LanePolicySource} from "../../utils/LanePolicySource.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Updates rate limiter configuration on a TokenPool, compatible with both v1 and v2 pools.
///
/// The direction(s) to update are inferred automatically: set OUTBOUND_* vars to update outbound,
/// INBOUND_* vars to update inbound, or both sets to update both. A direction with no env vars is
/// resolved from the declared `lanes{}` policy in `config/chains/<local>.json` when the matched lane
/// entry declares it (see the input ladder below). At least one direction must come from one of the
/// two sources.
///
/// Environment Variables (required):
///   DEST_CHAIN                    - The remote chain whose rate limit lane is being updated (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (set to update outbound — any one triggers the direction):
///   OUTBOUND_RATE_LIMIT_CAPACITY  - uint128, token bucket capacity (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_RATE      - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   OUTBOUND_RATE_LIMIT_ENABLED   - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///
/// Environment Variables (set to update inbound — any one triggers the direction):
///   INBOUND_RATE_LIMIT_CAPACITY   - uint128, token bucket capacity (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_RATE       - uint128, token bucket refill rate (isEnabled defaults to true when set)
///   INBOUND_RATE_LIMIT_ENABLED    - true/false (optional override; defaults to true if CAPACITY/RATE provided)
///
/// Environment Variables (optional, v2 only):
///   FAST_FINALITY                  - true/false, whether to update the fast finality rate limit
///                                   bucket (default: false, uses the standard finality bucket)
///
/// Rate-limit input resolution ladder (per direction — matching the repo's inline > env > registry
/// idiom, and the same ladder ApplyChainUpdates CLI mode uses):
///   1. Any of the direction's rate-limit env vars set → the env values win, byte-for-byte the
///      historical behavior above. When the local chain config declares a diverging policy for the
///      bucket being written, a one-line console notice names both values (`make doctor` WARNs
///      until reconciled) and the closing output prints a hand-edit remediation hint.
///   2. Env vars unset for a direction → the declared `lanes{}` policy supplies that bucket, scoped
///      to the bucket the script writes: the STANDARD bucket takes the core lane fields
///      (`capacity`/`rate` outbound, the optional `inbound{}` block inbound — the same fields
///      ApplyChainUpdates consumes), the FAST-FINALITY bucket (FAST_FINALITY=true on a 2.0.0 pool)
///      takes `v2.fastFinality.outbound` / `v2.fastFinality.inbound`, each direction declared only
///      when its block exists. A declared bucket is enabled iff capacity or rate is non-zero (the
///      doctor's inference); an absent block leaves the direction untouched, exactly as before.
///   3. Neither env vars nor a declared bucket for either direction → the historical error stands,
///      naming both remedies (the env vars, or declaring the lane policy).
/// lanes{} is owner intent — an env-driven apply never writes it back. There is no `make add-lane`
/// flag surface for the v2{} blocks (deliberate: they are declared by a reviewed hand edit), so the
/// closing hint is a hand-edit instruction; the doctor WARN closes the loop.
///
/// Version scope: the fast-finality bucket only exists on 2.0.0 pools. FAST_FINALITY=true on an
/// earlier pool keeps the historical fence (a warning; the standard bucket is written), and the
/// ladder consults the core lane fields in that case — the declared source always matches the
/// bucket actually written.
///
/// Usage examples:
///   # Enable both directions (isEnabled inferred from CAPACITY/RATE being set):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
///   OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
///   INBOUND_RATE_LIMIT_RATE=100000000000000000 \
///   forge script script/configure/rate-limiter/UpdateRateLimiters.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Disable outbound only:
///   DEST_CHAIN=MANTLE_SEPOLIA OUTBOUND_RATE_LIMIT_ENABLED=false \
///   forge script script/configure/rate-limiter/UpdateRateLimiters.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
///   # Apply the declared lanes{} policy (no env vars):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/rate-limiter/UpdateRateLimiters.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateRateLimiters is EoaExecutor, LanePolicySource {
    // ── Storage: shared between run() and helper functions ─────────────────
    // Using storage instead of function parameters eliminates EVM stack pressure.
    HelperConfig public helperConfig;
    address private s_poolAddress;
    uint64 private s_selector;
    bool private s_fastFinality;
    PoolVersions.Version private s_version;
    uint256 private s_chainId;

    /// @dev How the per-direction buckets were resolved through the input ladder, plus everything
    ///      the console (and the tests) need to explain the decision: which rung supplied each
    ///      direction, which lanes{} entry matched, whether an env override diverges from the
    ///      declared policy, and the hand-edit remediation hint state.
    struct RateLimitResolution {
        RateLimiterUtils.RateLimitUpdate update; // the final update (env- and lanes-sourced directions)
        bool fastFinality; // the bucket axis consulted (fast-finality vs standard/core fields)
        bool outboundFromEnv;
        bool inboundFromEnv;
        bool outboundFromLanes;
        bool inboundFromLanes;
        bool configFound; // config/chains/<configName>.json exists for the local chain
        string configName;
        bool laneFound;
        string laneKey;
        bool outboundDeclared; // the axis-scoped outbound bucket is declared
        uint256 outboundDeclCapacity;
        uint256 outboundDeclRate;
        bool inboundDeclared; // the axis-scoped inbound bucket is declared
        uint256 inboundDeclCapacity;
        uint256 inboundDeclRate;
        bool outboundDiverges; // env override differs from the declared policy
        bool inboundDiverges;
        bool editHint; // an env-driven apply left the declaration missing or diverging
        string outboundNotice; // composed divergence notice (empty unless outboundDiverges)
        string inboundNotice; // composed divergence notice (empty unless inboundDiverges)
        string outboundHint; // composed hand-edit hint (empty unless the outbound direction hints)
        string inboundHint; // composed hand-edit hint (empty unless the inbound direction hints)
    }

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        s_fastFinality = vm.envOr("FAST_FINALITY", false);

        // ── Rung 1: infer direction from which env vars are present ────────
        // Sentinel pattern: any OUTBOUND_* or INBOUND_* var triggers that direction.
        // isEnabled defaults to true when CAPACITY or RATE are provided.
        RateLimiterUtils.RateLimitUpdate memory envUpdate = _readRateLimitUpdate();

        // ── Resolve chain IDs / selectors, store in contract storage ───────
        helperConfig = new HelperConfig();
        s_chainId = block.chainid;
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        s_selector = helperConfig.getNetworkConfig(destChainId).chainSelector;

        // ── Resolve pool, detect version ───────────────────────────────────
        s_poolAddress = helperConfig.getDeployedTokenPool(s_chainId);
        require(
            s_poolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(s_chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );
        (PoolVersions.Version poolVersion, string memory poolTypeAndVersion) = PoolVersion.resolve(s_poolAddress);
        s_version = poolVersion;

        // ── Rung 2: a direction with no env vars takes the declared lanes{} policy ──
        // The axis follows the bucket actually written: FAST_FINALITY=true is ignored on v1 pools
        // (the historical fence below), so the ladder consults the core fields there too.
        bool fastFinalityBucket = s_fastFinality && s_version >= PoolVersions.Version.V2_0_0;
        RateLimitResolution memory res =
            _resolveRateLimitUpdate(envUpdate, destChainName, s_selector, fastFinalityBucket);

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⚡️ Update Rate Limiters");
        console.log("========================================");
        console.log(string.concat("Chain:        ", helperConfig.getChainName(s_chainId)));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(s_poolAddress)));
        console.log(string.concat("Action:       ", "Update rate limits"));
        console.log(
            string.concat(
                "Direction:    ", RateLimiterUtils.directionLabel(res.update.updateOutbound, res.update.updateInbound)
            )
        );
        console.log(s_fastFinality ? "Bucket:       Fast finality" : "Bucket:       Standard finality");
        console.log("========================================");
        console.log("");

        console.log(
            string.concat(
                "Pool Version: ",
                poolTypeAndVersion,
                s_version >= PoolVersions.Version.V2_0_0 ? " (setRateLimitConfig)" : " (setChainRateLimiterConfig)"
            )
        );
        console.log("");

        _logResolution(res, destChainName);

        RateLimiterUtils.logRateLimiterState(
            TokenPool(s_poolAddress), ITokenPoolV1RateLimiter(s_poolAddress), s_selector, s_fastFinality, s_version
        );

        // ── Build configs from on-chain state + update, then broadcast ─────
        _applyRateLimitUpdate(res.update);

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(
            string.concat(unicode"✅ Rate limiter update complete on ", helperConfig.getChainName(s_chainId), "!")
        );
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(s_poolAddress)));
        console.log(string.concat("Token Pool:   ", helperConfig.getExplorerUrl(s_chainId, "/address/", s_poolAddress)));
        console.log("========================================");
        _logEditHints(res);
        console.log("");
    }

    // ── Input resolution (env > lanes{} > historical error) ────────────────

    /// @dev Reads the rate-limit env vars through the env seams — byte-for-byte the semantics of
    ///      `RateLimiterUtils.readRateLimitUpdate` (which reads the process env directly and stays
    ///      untouched for its other consumers): any of a direction's vars triggers the direction,
    ///      isEnabled defaults to true when CAPACITY or RATE is set, ENABLED overrides explicitly.
    function _readRateLimitUpdate() internal view returns (RateLimiterUtils.RateLimitUpdate memory u) {
        bool outboundCapacitySet = _envExists("OUTBOUND_RATE_LIMIT_CAPACITY");
        bool outboundRateSet = _envExists("OUTBOUND_RATE_LIMIT_RATE");
        bool inboundCapacitySet = _envExists("INBOUND_RATE_LIMIT_CAPACITY");
        bool inboundRateSet = _envExists("INBOUND_RATE_LIMIT_RATE");

        u.updateOutbound = _envExists("OUTBOUND_RATE_LIMIT_ENABLED") || outboundCapacitySet || outboundRateSet;
        u.updateInbound = _envExists("INBOUND_RATE_LIMIT_ENABLED") || inboundCapacitySet || inboundRateSet;

        if (u.updateOutbound) {
            u.outboundEnabled = _envBool("OUTBOUND_RATE_LIMIT_ENABLED", outboundCapacitySet || outboundRateSet);
            u.outboundCapacity = uint128(_envUint("OUTBOUND_RATE_LIMIT_CAPACITY"));
            u.outboundRate = uint128(_envUint("OUTBOUND_RATE_LIMIT_RATE"));
        }
        if (u.updateInbound) {
            u.inboundEnabled = _envBool("INBOUND_RATE_LIMIT_ENABLED", inboundCapacitySet || inboundRateSet);
            u.inboundCapacity = uint128(_envUint("INBOUND_RATE_LIMIT_CAPACITY"));
            u.inboundRate = uint128(_envUint("INBOUND_RATE_LIMIT_RATE"));
        }
    }

    /// @dev Resolves the per-direction buckets through the input ladder (see the contract natspec).
    ///      `fastFinalityBucket` selects the declared surface consulted: the core lane fields for
    ///      the standard bucket, `v2.fastFinality.{outbound,inbound}` for the fast-finality bucket —
    ///      always the fields the doctor reconciles against the bucket being written. Ends with the
    ///      at-least-one-direction requirement, now naming both remedies. lanes{} is OWNER INTENT:
    ///      an env-driven apply never writes it back — the hand-edit hint plus the doctor WARN close
    ///      the loop through a reviewed edit by design.
    function _resolveRateLimitUpdate(
        RateLimiterUtils.RateLimitUpdate memory envUpdate,
        string memory destChainName,
        uint64 destChainSelector,
        bool fastFinalityBucket
    ) internal view returns (RateLimitResolution memory res) {
        res.update = envUpdate;
        res.fastFinality = fastFinalityBucket;
        res.outboundFromEnv = envUpdate.updateOutbound;
        res.inboundFromEnv = envUpdate.updateInbound;

        string memory json;
        (res.configFound, res.configName, json) = _findLocalChainConfig();
        if (res.configFound) (res.laneFound, res.laneKey) = _findLaneKey(json, destChainName, destChainSelector);
        if (res.laneFound) _readDeclaredBuckets(res, json);
        // When no entry matched, notices and hints still name the entry to declare: the remote's
        // config file basename (the key `make add-lane` would write).
        if (!res.laneFound) res.laneKey = _remoteConfigName(destChainName);

        // Rung 2: a direction with no env vars takes the declared bucket for the axis being
        // written. An undeclared bucket leaves the direction untouched, exactly as before.
        if (!res.outboundFromEnv && res.outboundDeclared) {
            res.outboundFromLanes = true;
            RateLimiter.Config memory declared = _declaredConfig(res.outboundDeclCapacity, res.outboundDeclRate);
            res.update.updateOutbound = true;
            res.update.outboundEnabled = declared.isEnabled;
            res.update.outboundCapacity = declared.capacity;
            res.update.outboundRate = declared.rate;
        }
        if (!res.inboundFromEnv && res.inboundDeclared) {
            res.inboundFromLanes = true;
            RateLimiter.Config memory declared = _declaredConfig(res.inboundDeclCapacity, res.inboundDeclRate);
            res.update.updateInbound = true;
            res.update.inboundEnabled = declared.isEnabled;
            res.update.inboundCapacity = declared.capacity;
            res.update.inboundRate = declared.rate;
        }

        // Rung 1 cross-check: an env override that disagrees with the declared policy is a notice,
        // never a revert (the doctor WARNs until reconciled). An undeclared bucket is not compared —
        // the same absent-means-undeclared rule the doctor applies.
        if (res.outboundFromEnv && res.outboundDeclared) {
            res.outboundDiverges =
                _bucketDiverges(_appliedConfig(res.update, false), res.outboundDeclCapacity, res.outboundDeclRate);
        }
        if (res.inboundFromEnv && res.inboundDeclared) {
            res.inboundDiverges =
                _bucketDiverges(_appliedConfig(res.update, true), res.inboundDeclCapacity, res.inboundDeclRate);
        }

        res.editHint = res.configFound
            && ((res.outboundFromEnv && (!res.outboundDeclared || res.outboundDiverges))
                || (res.inboundFromEnv && (!res.inboundDeclared || res.inboundDiverges)));

        // Compose the exact strings the console prints, on the struct, so the lane-source tests can
        // pin them byte-exact (mirroring ApplyChainUpdates' `addLaneCommand`).
        if (res.outboundDiverges) res.outboundNotice = _composeDivergence(res, false);
        if (res.inboundDiverges) res.inboundNotice = _composeDivergence(res, true);
        if (res.editHint) {
            if (res.outboundFromEnv && (!res.outboundDeclared || res.outboundDiverges)) {
                res.outboundHint = _composeEditHint(res, false);
            }
            if (res.inboundFromEnv && (!res.inboundDeclared || res.inboundDiverges)) {
                res.inboundHint = _composeEditHint(res, true);
            }
        }

        require(
            res.update.updateOutbound || res.update.updateInbound,
            string.concat(
                "At least one direction must be specified: set OUTBOUND_* and/or INBOUND_* rate limit env vars, or declare the ",
                fastFinalityBucket
                    ? "lanes.<remote>.v2.fastFinality.{outbound,inbound} bucket(s)"
                    : "lanes.<remote> policy (capacity/rate, optional inbound{})",
                " in config/chains/",
                res.configFound ? res.configName : "<local>",
                ".json"
            )
        );
    }

    /// @dev Fills the declared axis-scoped buckets for the matched lane entry. Standard bucket: the
    ///      core fields (`capacity`/`rate` are always declared on a lane entry — a missing key reads
    ///      0, i.e. declared-disabled — and `inbound{}` is declared only when present), the exact
    ///      fields ApplyChainUpdates consumes. Fast-finality bucket: `v2.fastFinality.<direction>`,
    ///      each direction declared only when its block exists (the doctor's absent-means-undeclared
    ///      rule, `VerifyChain._checkLanePolicy`).
    function _readDeclaredBuckets(RateLimitResolution memory res, string memory json) internal view {
        string memory lanePath = string.concat(".lanes.", res.laneKey);
        if (res.fastFinality) {
            string memory ftfPath = string.concat(lanePath, ".v2.fastFinality");
            if (vm.keyExistsJson(json, string.concat(ftfPath, ".outbound"))) {
                res.outboundDeclared = true;
                (res.outboundDeclCapacity, res.outboundDeclRate) =
                    _declaredBucket(json, string.concat(ftfPath, ".outbound"));
            }
            if (vm.keyExistsJson(json, string.concat(ftfPath, ".inbound"))) {
                res.inboundDeclared = true;
                (res.inboundDeclCapacity, res.inboundDeclRate) =
                    _declaredBucket(json, string.concat(ftfPath, ".inbound"));
            }
        } else {
            res.outboundDeclared = true;
            (res.outboundDeclCapacity, res.outboundDeclRate) = _declaredBucket(json, lanePath);
            if (vm.keyExistsJson(json, string.concat(lanePath, ".inbound"))) {
                res.inboundDeclared = true;
                (res.inboundDeclCapacity, res.inboundDeclRate) =
                    _declaredBucket(json, string.concat(lanePath, ".inbound"));
            }
        }
    }

    /// @dev One direction of the final update as a RateLimiter.Config, with the same
    ///      disabled-zeroes-values rule the apply uses.
    function _appliedConfig(RateLimiterUtils.RateLimitUpdate memory u, bool inbound)
        internal
        pure
        returns (RateLimiter.Config memory)
    {
        (bool enabled, uint128 capacity, uint128 rate) = inbound
            ? (u.inboundEnabled, u.inboundCapacity, u.inboundRate)
            : (u.outboundEnabled, u.outboundCapacity, u.outboundRate);
        return RateLimiter.Config({isEnabled: enabled, capacity: enabled ? capacity : 0, rate: enabled ? rate : 0});
    }

    /// @dev The declared path of one direction's bucket for the axis, used by every notice/hint.
    function _bucketPath(RateLimitResolution memory res, bool inbound) internal pure returns (string memory) {
        string memory laneEntry = string.concat("lanes.", res.laneKey);
        if (res.fastFinality) {
            return string.concat(laneEntry, ".v2.fastFinality.", inbound ? "inbound" : "outbound");
        }
        return inbound ? string.concat(laneEntry, ".inbound") : laneEntry;
    }

    /// @dev The resolution-ladder console lines: which rung supplied the buckets, and the
    ///      per-direction divergence notice (a notice, not a revert) naming both values and the
    ///      declared entry path.
    function _logResolution(RateLimitResolution memory res, string memory destChainName) internal pure {
        if (res.outboundFromLanes || res.inboundFromLanes) {
            console.log(
                string.concat(
                    "Rate limits resolved from lanes.",
                    res.laneKey,
                    res.fastFinality ? ".v2.fastFinality" : "",
                    " in config/chains/",
                    res.configName,
                    ".json (",
                    res.outboundFromLanes ? (res.inboundFromLanes ? "outbound + inbound" : "outbound") : "inbound",
                    ")"
                )
            );
            console.log("");
        }
        if (res.outboundDiverges) console.log(res.outboundNotice);
        if (res.inboundDiverges) console.log(res.inboundNotice);
        if ((res.outboundDiverges || res.inboundDiverges)) console.log("");
        if (!res.laneFound && (res.outboundFromEnv || res.inboundFromEnv) && res.configFound) {
            console.log(
                string.concat(
                    "No lanes{} entry for ",
                    destChainName,
                    " in config/chains/",
                    res.configName,
                    ".json; applying the env values (declare the lane to make the policy reviewable)"
                )
            );
            console.log("");
        }
    }

    /// @dev One divergence-notice line for one direction, naming the applied env values, the
    ///      declared values, and the declared entry path. Returns the composed string (stored on the
    ///      resolution struct and printed verbatim) so tests can pin it byte-exact.
    function _composeDivergence(RateLimitResolution memory res, bool inbound) internal pure returns (string memory) {
        RateLimiter.Config memory applied = _appliedConfig(res.update, inbound);
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
            ") diverges from declared ",
            _bucketPath(res, inbound),
            " (capacity=",
            vm.toString(declCapacity),
            " rate=",
            vm.toString(declRate),
            ") in config/chains/",
            res.configName,
            ".json - make doctor will WARN until reconciled"
        );
    }

    /// @dev The closing remediation hints. lanes{} is owner intent — applies never auto-write it,
    ///      and `make add-lane` has no flag surface for the v2{} blocks (deliberate), so the hint is
    ///      a hand-edit instruction; the doctor WARN closes the loop through a reviewed edit.
    function _logEditHints(RateLimitResolution memory res) internal pure {
        if (!res.editHint) return;
        if (bytes(res.outboundHint).length != 0) console.log(res.outboundHint);
        if (bytes(res.inboundHint).length != 0) console.log(res.inboundHint);
    }

    /// @dev One hand-edit hint line for one env-driven direction whose declaration is missing or
    ///      diverging: the entry path, the file, the applied values to declare, and the doctor WARN.
    ///      Returns the composed string (stored on the resolution struct and printed verbatim) so
    ///      tests can pin it byte-exact.
    function _composeEditHint(RateLimitResolution memory res, bool inbound) internal pure returns (string memory) {
        RateLimiter.Config memory applied = _appliedConfig(res.update, inbound);
        return string.concat(
            unicode"⚠️  Applied ",
            inbound ? "INBOUND" : "OUTBOUND",
            " values are ",
            (inbound ? res.inboundDeclared : res.outboundDeclared) ? "diverging from" : "not declared in",
            " ",
            _bucketPath(res, inbound),
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

    // ── Internal helpers ───────────────────────────────────────────────────

    /// @dev Merges on-chain state with user input, logs the result, and broadcasts.
    function _applyRateLimitUpdate(RateLimiterUtils.RateLimitUpdate memory u) internal {
        // Seed from live state so untouched directions keep their current values.
        (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) = RateLimiterUtils.getCurrentConfigs(
            TokenPool(s_poolAddress), ITokenPoolV1RateLimiter(s_poolAddress), s_selector, s_fastFinality, s_version
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
        _broadcastRateLimitConfig(outbound, inbound);
    }

    /// @dev Routes the update through the version-dispatched action layer: pools at 2.0.0 and later
    ///      take `setRateLimitConfig(RateLimitConfigArgs[])`, earlier cataloged versions take
    ///      `setChainRateLimiterConfig`. `s_version` was resolved from on-chain `typeAndVersion()` by
    ///      `PoolVersion.resolve` above (resolution stays script-side; the builder takes the enum).
    function _broadcastRateLimitConfig(RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) internal {
        if (s_version < PoolVersions.Version.V2_0_0 && s_fastFinality) {
            console.log(
                unicode"⚠️  Warning: FAST_FINALITY=true is ignored on v1 pools. Updating the standard bucket."
            );
        }
        executeCalls(CctActions.setRateLimits(s_poolAddress, s_version, s_selector, s_fastFinality, outbound, inbound));
    }
}
