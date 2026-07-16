// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {ApplyChainUpdates} from "../../script/setup/ApplyChainUpdates.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev Exposes ApplyChainUpdates' rate-limit input resolution with the env access swapped for an
///      injectable fake (the `_rlEnv*` seams exist for exactly this: env vars are process-global
///      and forge runs suites in parallel, so tests must never vm.setEnv shared names). An unset
///      fake var behaves like an unset env var; the resolution logic under test is unmodified.
contract LaneSourceHarness is ApplyChainUpdates {
    mapping(bytes32 => string) private fakeEnv;

    function setFakeEnv(string memory name, string memory value) external {
        fakeEnv[keccak256(bytes(name))] = value;
    }

    function _rlEnvExists(string memory name) internal view override returns (bool) {
        return bytes(fakeEnv[keccak256(bytes(name))]).length != 0;
    }

    function _rlEnvUint(string memory name) internal view override returns (uint256) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? 0 : vm.parseUint(value);
    }

    function _rlEnvBool(string memory name, bool defaultValue) internal view override returns (bool) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? defaultValue : vm.parseBool(value);
    }

    function resolve(string memory destChainName, uint64 destChainSelector)
        external
        view
        returns (RateLimitResolution memory)
    {
        return _resolveRateLimiterConfigs(destChainName, destChainSelector);
    }
}

/// @notice The CLI-mode rate-limit input-resolution ladder of ApplyChainUpdates
///         (env > lanes{} > disabled default, per direction), proven offline against scratch chain
///         configs: rung-1 env byte-equality (with and without a declared lane, agreeing and
///         diverging), rung-2 lanes{} consumption (core outbound, optional inbound{}, declared-
///         disabled 0/0), the rung-3 historical default, the name-then-selector lane matching, and
///         the `make add-lane` remediation hint states (undeclared -> hint with the applied values,
///         diverging -> divergence flag + hint, agreeing or lanes-sourced -> no hint). Each test
///         writes its own uniquely-named scratch chain and pins block.chainid to that chain's
///         declared chainId via vm.chainId (test-local, no process-global state).
contract ApplyChainUpdatesLaneSourceTest is LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_871_000_000_000_000_001;
    uint128 internal constant ENV_CAPACITY = 5000e18;
    uint128 internal constant ENV_RATE = 50e18;
    uint128 internal constant LANE_CAPACITY = 1000e18;
    uint128 internal constant LANE_RATE = 10e18;
    uint128 internal constant LANE_INBOUND_CAPACITY = 700e18;
    uint128 internal constant LANE_INBOUND_RATE = 7e18;

    LaneSourceHarness internal harness;

    function setUp() public {
        _clean();
        harness = new LaneSourceHarness();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](17);
        for (uint256 n = 1; n <= 14; n++) {
            names[n - 1] = string.concat("zz-scratch-lanesrc-l", vm.toString(n));
        }
        names[14] = "zz-scratch-lanesrc-r1";
        names[15] = "zz-scratch-lanesrc-r6";
        names[16] = "zz-scratch-lanesrc-r12";
        _cleanupScratch(names);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Writes the local scratch chain and pins block.chainid to it, so the resolution's
    ///      local-config discovery finds exactly this file.
    function _localChain(uint256 n) internal returns (string memory name) {
        name = string.concat("zz-scratch-lanesrc-l", vm.toString(n));
        uint256 chainId = 887_101_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_871_010_000_000_000_000 + n * 100 + 1));
        vm.chainId(chainId);
    }

    function _setOutboundEnv(uint256 capacity, uint256 rate) internal {
        harness.setFakeEnv("OUTBOUND_RATE_LIMIT_CAPACITY", vm.toString(capacity));
        harness.setFakeEnv("OUTBOUND_RATE_LIMIT_RATE", vm.toString(rate));
    }

    function _setInboundEnv(uint256 capacity, uint256 rate) internal {
        harness.setFakeEnv("INBOUND_RATE_LIMIT_CAPACITY", vm.toString(capacity));
        harness.setFakeEnv("INBOUND_RATE_LIMIT_RATE", vm.toString(rate));
    }

    function _assertBucket(RateLimiter.Config memory bucket, bool enabled, uint256 capacity, uint256 rate)
        internal
        pure
    {
        assertEq(bucket.isEnabled, enabled, "bucket isEnabled");
        assertEq(bucket.capacity, capacity, "bucket capacity");
        assertEq(bucket.rate, rate, "bucket rate");
    }

    function _expectedCommand(string memory local, string memory remote) internal pure returns (string memory) {
        return string.concat(
            "make add-lane LOCAL=",
            local,
            " REMOTE=",
            remote,
            " CAPACITY=",
            vm.toString(uint256(ENV_CAPACITY)),
            " RATE=",
            vm.toString(uint256(ENV_RATE))
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 1: env vars set
    // ─────────────────────────────────────────────────────────────────────────

    // Env set, no lanes{} entry: buckets identical to the historical env behavior (outbound
    // enabled with the given values, inbound disabled), and the closing hint carries the exact
    // add-lane command with the values just applied (hint state a). The destination name is the
    // remote's config file basename, so the hint's REMOTE resolves to it directly.
    function test_EnvOnly_NoLaneEntry_EnvBucketsPinned_AndHintComposed() public {
        string memory local = _localChain(1);
        _writeScratchChain("zz-scratch-lanesrc-r1", 887_101_901, 8_871_019_010_000_000_001);
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("zz-scratch-lanesrc-r1", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, ENV_RATE);
        _assertBucket(res.inbound, false, 0, 0);
        assertTrue(res.outboundFromEnv, "outbound must come from env");
        assertFalse(res.inboundFromEnv, "inbound env vars are unset");
        assertFalse(res.lane.found, "no lane entry to find");
        assertTrue(res.configFound, "local config must be discovered");
        assertEq(res.configName, local, "wrong local config matched");
        assertFalse(res.outboundDiverges, "no declared policy, nothing to diverge from");
        assertTrue(res.addLaneHint, "env apply with an undeclared lane must hint");
        assertEq(res.addLaneCommand, _expectedCommand(local, "zz-scratch-lanesrc-r1"), "hint command");

        _cleanupScratchOne(local);
        vm.removeFile(_path("zz-scratch-lanesrc-r1"));
    }

    // Env set, lanes{} entry AGREES: env used, no divergence, NO hint (hint state c).
    function test_EnvAndLaneAgree_EnvUsed_NoDivergence_NoHint() public {
        string memory local = _localChain(2);
        _declareLane(local, "zz-scratch-lanesrc-remote2", _laneEntry(REMOTE_SELECTOR, ENV_CAPACITY, ENV_RATE, ""));
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote2", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, ENV_RATE);
        assertTrue(res.outboundFromEnv, "outbound must come from env");
        assertTrue(res.lane.found, "lane entry must match by key name");
        assertFalse(res.outboundDiverges, "agreeing env values must not flag divergence");
        assertFalse(res.addLaneHint, "an agreeing declaration needs no hint");

        _cleanupScratchOne(local);
    }

    // Env set, lanes{} entry DIVERGES: env wins (buckets == env), divergence detected, and the
    // hint follows with the APPLIED (env) values (hint state b).
    function test_EnvAndLaneDiverge_EnvWins_DivergenceFlagged_HintWithAppliedValues() public {
        string memory local = _localChain(3);
        _declareLane(local, "zz-scratch-lanesrc-remote3", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote3", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, ENV_RATE);
        assertTrue(res.lane.found, "lane entry must match");
        assertEq(res.lane.capacity, LANE_CAPACITY, "declared capacity parsed");
        assertEq(res.lane.rate, LANE_RATE, "declared rate parsed");
        assertTrue(res.outboundDiverges, "diverging env override must be flagged");
        assertTrue(res.addLaneHint, "a diverging declaration must hint");
        assertEq(
            res.addLaneCommand, _expectedCommand(local, "zz-scratch-lanesrc-remote3"), "hint carries applied values"
        );

        _cleanupScratchOne(local);
    }

    // ENABLED=false alone is an env override too (incident response: explicitly disable): env wins
    // with a disabled bucket, the enabled declared policy is flagged as divergence, hint follows.
    function test_EnabledFalseOnly_EnvWins_DivergenceAndHint() public {
        string memory local = _localChain(10);
        _declareLane(local, "zz-scratch-lanesrc-remote10", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));
        harness.setFakeEnv("OUTBOUND_RATE_LIMIT_ENABLED", "false");

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote10", REMOTE_SELECTOR);

        _assertBucket(res.outbound, false, 0, 0);
        assertTrue(res.outboundFromEnv, "ENABLED alone must select the env rung");
        assertTrue(res.outboundDiverges, "disabled override vs enabled declaration must diverge");
        assertTrue(res.addLaneHint, "divergence must hint");

        _cleanupScratchOne(local);
    }

    // CAPACITY alone: isEnabled defaults to true and the unset RATE reads 0 — the exact historical
    // env semantics, pinned.
    function test_CapacityOnly_EnabledDefaultsTrue_RateZero() public {
        string memory local = _localChain(13);
        harness.setFakeEnv("OUTBOUND_RATE_LIMIT_CAPACITY", vm.toString(uint256(ENV_CAPACITY)));

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("zz-scratch-lanesrc-none13", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, 0);
        _assertBucket(res.inbound, false, 0, 0);
        assertTrue(res.outboundFromEnv, "CAPACITY alone must select the env rung");

        _cleanupScratchOne(local);
    }

    // Env inbound enabled and no lane entry: the hint includes the INBOUND pair.
    function test_EnvInboundEnabled_HintIncludesInboundPair() public {
        string memory local = _localChain(12);
        _writeScratchChain("zz-scratch-lanesrc-r12", 887_101_912, 8_871_019_120_000_000_001);
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);
        _setInboundEnv(LANE_INBOUND_CAPACITY, LANE_INBOUND_RATE);

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("zz-scratch-lanesrc-r12", REMOTE_SELECTOR);

        _assertBucket(res.inbound, true, LANE_INBOUND_CAPACITY, LANE_INBOUND_RATE);
        assertTrue(res.addLaneHint, "undeclared lane must hint");
        assertEq(
            res.addLaneCommand,
            string.concat(
                _expectedCommand(local, "zz-scratch-lanesrc-r12"),
                " INBOUND_CAPACITY=",
                vm.toString(uint256(LANE_INBOUND_CAPACITY)),
                " INBOUND_RATE=",
                vm.toString(uint256(LANE_INBOUND_RATE))
            ),
            "hint must carry the applied inbound pair"
        );

        _cleanupScratchOne(local);
        vm.removeFile(_path("zz-scratch-lanesrc-r12"));
    }

    // No local config file for block.chainid: env values apply as before and no hint is composed
    // (there is no lanes{} to declare into).
    function test_NoLocalConfig_EnvUsed_NoHint() public {
        vm.chainId(887_109_999); // no config/chains file declares this chainId
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("zz-scratch-lanesrc-none14", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, ENV_RATE);
        assertFalse(res.configFound, "no local config must be found");
        assertFalse(res.lane.found, "no lane without a config");
        assertFalse(res.addLaneHint, "no config file, nothing to declare into");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 2: env vars unset, lanes{} declared
    // ─────────────────────────────────────────────────────────────────────────

    // Core-only lane entry: outbound from lanes{} (enabled, declared values); the ABSENT inbound{}
    // block keeps the env-absent default (disabled). Lanes-sourced applies never hint (state d).
    function test_NoEnv_LaneCoreOnly_OutboundFromLanes_InboundDefaultDisabled() public {
        string memory local = _localChain(4);
        _declareLane(local, "zz-scratch-lanesrc-remote4", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote4", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, LANE_CAPACITY, LANE_RATE);
        _assertBucket(res.inbound, false, 0, 0);
        assertTrue(res.outboundFromLanes, "outbound must come from lanes{}");
        assertFalse(res.inboundFromLanes, "absent inbound{} keeps the env-absent default");
        assertFalse(res.outboundDiverges, "nothing to diverge without an env override");
        assertFalse(res.addLaneHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // Lane entry with an inbound{} block: both buckets from lanes{}. No hint (state d).
    function test_NoEnv_LaneWithInbound_BothFromLanes() public {
        string memory local = _localChain(5);
        string memory inboundBlock = string.concat(
            ",\"inbound\":{\"capacity\":\"",
            vm.toString(uint256(LANE_INBOUND_CAPACITY)),
            "\",\"rate\":\"",
            vm.toString(uint256(LANE_INBOUND_RATE)),
            "\"}"
        );
        _declareLane(
            local, "zz-scratch-lanesrc-remote5", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, inboundBlock)
        );

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote5", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, LANE_CAPACITY, LANE_RATE);
        _assertBucket(res.inbound, true, LANE_INBOUND_CAPACITY, LANE_INBOUND_RATE);
        assertTrue(res.outboundFromLanes, "outbound must come from lanes{}");
        assertTrue(res.inboundFromLanes, "declared inbound{} must drive the inbound bucket");
        assertFalse(res.addLaneHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // A declared 0/0 bucket is declared-disabled (enabled iff capacity or rate non-zero — the same
    // inference the doctor's lanes rung uses).
    function test_NoEnv_DeclaredZeroZero_IsDeclaredDisabled() public {
        string memory local = _localChain(9);
        _declareLane(local, "zz-scratch-lanesrc-remote9", _laneEntry(REMOTE_SELECTOR, 0, 0, ""));

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote9", REMOTE_SELECTOR);

        _assertBucket(res.outbound, false, 0, 0);
        assertTrue(res.outboundFromLanes, "declared-disabled still comes from lanes{}");

        _cleanupScratchOne(local);
    }

    // Mixed: outbound env override agreeing with the declaration, inbound resolved from the
    // declared inbound{} block. Nothing diverges, so no hint.
    function test_Mixed_OutboundEnvAgrees_InboundFromLanes_NoHint() public {
        string memory local = _localChain(11);
        string memory inboundBlock = string.concat(
            ",\"inbound\":{\"capacity\":\"",
            vm.toString(uint256(LANE_INBOUND_CAPACITY)),
            "\",\"rate\":\"",
            vm.toString(uint256(LANE_INBOUND_RATE)),
            "\"}"
        );
        _declareLane(
            local, "zz-scratch-lanesrc-remote11", _laneEntry(REMOTE_SELECTOR, ENV_CAPACITY, ENV_RATE, inboundBlock)
        );
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        ApplyChainUpdates.RateLimitResolution memory res =
            harness.resolve("zz-scratch-lanesrc-remote11", REMOTE_SELECTOR);

        _assertBucket(res.outbound, true, ENV_CAPACITY, ENV_RATE);
        _assertBucket(res.inbound, true, LANE_INBOUND_CAPACITY, LANE_INBOUND_RATE);
        assertTrue(res.outboundFromEnv, "outbound must come from env");
        assertTrue(res.inboundFromLanes, "inbound must come from the declared inbound{}");
        assertFalse(res.outboundDiverges, "agreeing override must not diverge");
        assertFalse(res.addLaneHint, "nothing diverges, no hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 3: neither env vars nor a lanes{} entry
    // ─────────────────────────────────────────────────────────────────────────

    // The historical env-absent default stands: both buckets disabled.
    function test_NoEnv_NoLane_DisabledDefaults() public {
        string memory local = _localChain(6);

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("zz-scratch-lanesrc-none6", REMOTE_SELECTOR);

        _assertBucket(res.outbound, false, 0, 0);
        _assertBucket(res.inbound, false, 0, 0);
        assertFalse(res.outboundFromEnv, "no env vars set");
        assertFalse(res.outboundFromLanes, "no lane entry declared");
        assertFalse(res.lane.found, "no lane entry to find");
        assertTrue(res.configFound, "local config still discovered");
        assertFalse(res.addLaneHint, "no env-driven apply, no hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lane matching: name first, then remoteSelector fallback
    // ─────────────────────────────────────────────────────────────────────────

    // DEST_CHAIN carries the remote's chainNameIdentifier, not the lanes key: the entry still
    // matches by name (the key's config file declares that identifier). The entry's
    // remoteSelector is deliberately different from the passed selector, proving the name rung
    // matched, not the selector fallback.
    function test_NameMatch_ByChainNameIdentifier() public {
        string memory local = _localChain(7);
        // The scratch shape hard-codes chainNameIdentifier "ZZ_SCRATCH_LANECHK".
        _writeScratchChain("zz-scratch-lanesrc-r6", 887_101_906, 8_871_019_060_000_000_001);
        _declareLane(local, "zz-scratch-lanesrc-r6", _laneEntry(999, LANE_CAPACITY, LANE_RATE, ""));

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("ZZ_SCRATCH_LANECHK", REMOTE_SELECTOR);

        assertTrue(res.lane.found, "identifier must match the lane key's config file");
        assertEq(res.lane.key, "zz-scratch-lanesrc-r6", "wrong lane key matched");
        _assertBucket(res.outbound, true, LANE_CAPACITY, LANE_RATE);

        _cleanupScratchOne(local);
        vm.removeFile(_path("zz-scratch-lanesrc-r6"));
    }

    // The lanes key names no config file and differs from the destination name, but the entry's
    // remoteSelector equals the destination selector: the selector fallback matches it.
    function test_SelectorFallback_MatchesWhenKeyNameDiffers() public {
        string memory local = _localChain(8);
        _declareLane(local, "zz-scratch-lanesrc-ghost8", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));

        ApplyChainUpdates.RateLimitResolution memory res = harness.resolve("ZZ_LANESRC_NO_SUCH_ID", REMOTE_SELECTOR);

        assertTrue(res.lane.found, "remoteSelector equality must match the entry");
        assertEq(res.lane.key, "zz-scratch-lanesrc-ghost8", "wrong lane key matched");
        _assertBucket(res.outbound, true, LANE_CAPACITY, LANE_RATE);

        _cleanupScratchOne(local);
    }
}
