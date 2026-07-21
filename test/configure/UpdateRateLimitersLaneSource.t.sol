// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiterUtils} from "../../script/utils/RateLimiterUtils.s.sol";
import {UpdateRateLimiters} from "../../script/configure/rate-limiter/UpdateRateLimiters.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev Exposes UpdateRateLimiters' input resolution with the env access swapped for an injectable
///      fake (the `_env*` seams exist for exactly this: env vars are process-global and forge runs
///      suites in parallel, so tests must never vm.setEnv shared names). An unset fake var behaves
///      like an unset env var; the resolution logic under test is unmodified. `fastFinality` is a
///      parameter because run() derives it from FAST_FINALITY + the resolved pool version - the
///      axis fence itself is plain `s_fastFinality && version >= V2_0_0` and needs no fork to trust.
contract RateLimitersLaneSourceHarness is UpdateRateLimiters {
    mapping(bytes32 => string) private fakeEnv;

    function setFakeEnv(string memory name, string memory value) external {
        fakeEnv[keccak256(bytes(name))] = value;
    }

    function _envExists(string memory name) internal view override returns (bool) {
        return bytes(fakeEnv[keccak256(bytes(name))]).length != 0;
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? 0 : vm.parseUint(value);
    }

    function _envBool(string memory name, bool defaultValue) internal view override returns (bool) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? defaultValue : vm.parseBool(value);
    }

    function resolve(string memory destChainName, uint64 destChainSelector, bool fastFinalityBucket)
        external
        view
        returns (RateLimitResolution memory)
    {
        return _resolveRateLimitUpdate(_readRateLimitUpdate(), destChainName, destChainSelector, fastFinalityBucket);
    }
}

/// @notice The per-direction rate-limit input ladder of UpdateRateLimiters (env > lanes{} >
///         historical error), proven offline against scratch chain configs, on both bucket axes:
///         the STANDARD bucket consumes the core lane fields (`capacity`/`rate`, optional
///         `inbound{}` - the same fields ApplyChainUpdates consumes), the FAST-FINALITY bucket
///         consumes `v2.fastFinality.{outbound,inbound}`, each direction declared only when its
///         block exists. Rung-1 env byte-equality (agreeing, diverging, ENABLED=false-only),
///         rung-2 lanes{} consumption (untouched direction stays untouched - the script's
///         historical semantics for an unset direction), the rung-3 both-remedies error, the
///         name-then-selector lane matching, and the hand-edit hint states. Each test writes its
///         own uniquely-named scratch chain and pins block.chainid to that chain's declared chainId
///         via vm.chainId (test-local, no process-global state).
contract UpdateRateLimitersLaneSourceTest is LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_872_000_000_000_000_001;
    uint128 internal constant ENV_CAPACITY = 5000e18;
    uint128 internal constant ENV_RATE = 50e18;
    uint128 internal constant LANE_CAPACITY = 1000e18;
    uint128 internal constant LANE_RATE = 10e18;
    uint128 internal constant LANE_INBOUND_CAPACITY = 700e18;
    uint128 internal constant LANE_INBOUND_RATE = 7e18;
    uint128 internal constant FTF_CAPACITY = 300e18;
    uint128 internal constant FTF_RATE = 3e18;
    uint128 internal constant FTF_INBOUND_CAPACITY = 200e18;
    uint128 internal constant FTF_INBOUND_RATE = 2e18;

    RateLimitersLaneSourceHarness internal harness;

    function setUp() public {
        _clean();
        harness = new RateLimitersLaneSourceHarness();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](15);
        for (uint256 n = 1; n <= 14; n++) {
            names[n - 1] = string.concat("zz-scratch-rlsrc-l", vm.toString(n));
        }
        names[14] = "zz-scratch-rlsrc-r1";
        _cleanupScratch(names);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Writes the local scratch chain and pins block.chainid to it, so the resolution's
    ///      local-config discovery finds exactly this file.
    function _localChain(uint256 n) internal returns (string memory name) {
        name = string.concat("zz-scratch-rlsrc-l", vm.toString(n));
        uint256 chainId = 887_201_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_872_010_000_000_000_000 + n * 100 + 1));
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

    /// @dev A `,"v2":{"fastFinality":{...}}` suffix for `_laneEntry` with the given direction blocks
    ///      (empty string omits a direction - absent means undeclared).
    function _ftfBlock(string memory outboundJson, string memory inboundJson) internal pure returns (string memory) {
        string memory inner = outboundJson;
        if (bytes(outboundJson).length != 0 && bytes(inboundJson).length != 0) {
            inner = string.concat(inner, ",");
        }
        inner = string.concat(inner, inboundJson);
        return string.concat(",\"v2\":{\"fastFinality\":{", inner, "}}");
    }

    function _ftfDirection(string memory direction, uint256 capacity, uint256 rate)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "\"", direction, "\":{\"capacity\":\"", vm.toString(capacity), "\",\"rate\":\"", vm.toString(rate), "\"}"
        );
    }

    function _assertOutbound(
        RateLimiterUtils.RateLimitUpdate memory u,
        bool updated,
        bool enabled,
        uint256 capacity,
        uint256 rate
    ) internal pure {
        assertEq(u.updateOutbound, updated, "updateOutbound");
        assertEq(u.outboundEnabled, enabled, "outboundEnabled");
        assertEq(u.outboundCapacity, capacity, "outboundCapacity");
        assertEq(u.outboundRate, rate, "outboundRate");
    }

    function _assertInbound(
        RateLimiterUtils.RateLimitUpdate memory u,
        bool updated,
        bool enabled,
        uint256 capacity,
        uint256 rate
    ) internal pure {
        assertEq(u.updateInbound, updated, "updateInbound");
        assertEq(u.inboundEnabled, enabled, "inboundEnabled");
        assertEq(u.inboundCapacity, capacity, "inboundCapacity");
        assertEq(u.inboundRate, rate, "inboundRate");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Standard bucket: rung 1 (env vars set)
    // ─────────────────────────────────────────────────────────────────────────

    // Env set, no lanes{} entry: the update is identical to the historical env behavior (outbound
    // updated with the given values, inbound untouched), and the hand-edit hint is armed. The
    // destination name is the remote's config file basename, so the hint entry resolves to it.
    function test_Std_EnvOnly_NoLaneEntry_EnvPinned_HintArmed() public {
        string memory local = _localChain(1);
        _writeScratchChain("zz-scratch-rlsrc-r1", 887_201_901, 8_872_019_010_000_000_001);
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-r1", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, true, ENV_CAPACITY, ENV_RATE);
        _assertInbound(res.update, false, false, 0, 0);
        assertTrue(res.outboundFromEnv, "outbound must come from env");
        assertFalse(res.inboundFromEnv, "inbound env vars are unset");
        assertFalse(res.laneFound, "no lane entry to find");
        assertTrue(res.configFound, "local config must be discovered");
        assertEq(res.configName, local, "wrong local config matched");
        assertEq(res.laneKey, "zz-scratch-rlsrc-r1", "hint entry key must be the remote basename");
        assertFalse(res.outboundDiverges, "no declared policy, nothing to diverge from");
        assertTrue(res.editHint, "env apply with an undeclared lane must hint");
        // Byte-exact pin of the composed hand-edit hint (undeclared standard bucket).
        assertEq(
            res.outboundHint,
            string.concat(
                unicode"⚠️  Applied OUTBOUND values are not declared in lanes.zz-scratch-rlsrc-r1 (project/",
                local,
                ".json). Hand-edit the entry to capacity=",
                vm.toString(uint256(ENV_CAPACITY)),
                " rate=",
                vm.toString(uint256(ENV_RATE)),
                " - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed undeclared hint"
        );
        assertEq(res.inboundHint, "", "inbound direction has no hint");

        _cleanupScratchOne(local);
        vm.removeFile(_path("zz-scratch-rlsrc-r1"));
    }

    // Env set, lanes{} entry AGREES on the core fields: env used, no divergence, no hint.
    function test_Std_EnvAndLaneAgree_NoDivergence_NoHint() public {
        string memory local = _localChain(2);
        _declareLane(local, "zz-scratch-rlsrc-remote2", _laneEntry(REMOTE_SELECTOR, ENV_CAPACITY, ENV_RATE, ""));
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote2", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, true, ENV_CAPACITY, ENV_RATE);
        assertTrue(res.laneFound, "lane entry must match by key name");
        assertTrue(res.outboundDeclared, "core fields are always declared on a matched lane");
        assertFalse(res.outboundDiverges, "agreeing env values must not flag divergence");
        assertFalse(res.editHint, "an agreeing declaration needs no hint");

        _cleanupScratchOne(local);
    }

    // Env set, lanes{} entry DIVERGES: env wins (the update carries the env values), divergence
    // detected, hint armed.
    function test_Std_EnvAndLaneDiverge_EnvWins_DivergenceAndHint() public {
        string memory local = _localChain(3);
        _declareLane(local, "zz-scratch-rlsrc-remote3", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote3", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, true, ENV_CAPACITY, ENV_RATE);
        assertEq(res.outboundDeclCapacity, LANE_CAPACITY, "declared capacity parsed");
        assertEq(res.outboundDeclRate, LANE_RATE, "declared rate parsed");
        assertTrue(res.outboundDiverges, "diverging env override must be flagged");
        assertTrue(res.editHint, "a diverging declaration must hint");
        // Byte-exact pin of the composed divergence notice (env override vs declared standard bucket).
        assertEq(
            res.outboundNotice,
            string.concat(
                unicode"⚠️  OUTBOUND rate-limit env override (enabled=true capacity=",
                vm.toString(uint256(ENV_CAPACITY)),
                " rate=",
                vm.toString(uint256(ENV_RATE)),
                ") diverges from declared lanes.zz-scratch-rlsrc-remote3 (capacity=",
                vm.toString(uint256(LANE_CAPACITY)),
                " rate=",
                vm.toString(uint256(LANE_RATE)),
                ") in project/",
                local,
                ".json - make doctor will FAIL until reconciled"
            ),
            "composed divergence notice"
        );

        _cleanupScratchOne(local);
    }

    // ENABLED=false alone is an env override too (incident response: explicitly disable): env wins
    // with a disabled bucket, the enabled declared policy is flagged as divergence.
    function test_Std_EnabledFalseOnly_EnvWins_Diverges() public {
        string memory local = _localChain(4);
        _declareLane(local, "zz-scratch-rlsrc-remote4", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));
        harness.setFakeEnv("OUTBOUND_RATE_LIMIT_ENABLED", "false");

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote4", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, false, 0, 0);
        assertTrue(res.outboundFromEnv, "ENABLED alone must select the env rung");
        assertTrue(res.outboundDiverges, "disabled override vs enabled declaration must diverge");
        assertTrue(res.editHint, "divergence must hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Standard bucket: rung 2 (env vars unset, lanes{} declared)
    // ─────────────────────────────────────────────────────────────────────────

    // Core-only lane entry: outbound from lanes{} (enabled, declared values); the ABSENT inbound{}
    // block leaves the inbound direction UNTOUCHED - the script's historical semantics for a
    // direction with no input (the live bucket is kept), unlike ApplyChainUpdates' disabled default.
    function test_Std_NoEnv_LaneCoreOnly_OutboundFromLanes_InboundUntouched() public {
        string memory local = _localChain(5);
        _declareLane(local, "zz-scratch-rlsrc-remote5", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote5", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, true, LANE_CAPACITY, LANE_RATE);
        _assertInbound(res.update, false, false, 0, 0);
        assertTrue(res.outboundFromLanes, "outbound must come from lanes{}");
        assertFalse(res.inboundFromLanes, "absent inbound{} must leave the direction untouched");
        assertFalse(res.editHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // Lane entry with an inbound{} block: both directions from lanes{}. No hint.
    function test_Std_NoEnv_LaneWithInbound_BothFromLanes() public {
        string memory local = _localChain(6);
        string memory inboundBlock = string.concat(
            ",\"inbound\":{\"capacity\":\"",
            vm.toString(uint256(LANE_INBOUND_CAPACITY)),
            "\",\"rate\":\"",
            vm.toString(uint256(LANE_INBOUND_RATE)),
            "\"}"
        );
        _declareLane(
            local, "zz-scratch-rlsrc-remote6", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, inboundBlock)
        );

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote6", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, true, LANE_CAPACITY, LANE_RATE);
        _assertInbound(res.update, true, true, LANE_INBOUND_CAPACITY, LANE_INBOUND_RATE);
        assertTrue(res.outboundFromLanes, "outbound must come from lanes{}");
        assertTrue(res.inboundFromLanes, "declared inbound{} must drive the inbound direction");
        assertFalse(res.editHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // A declared 0/0 bucket is declared-disabled (enabled iff capacity or rate non-zero - the same
    // inference the doctor's lanes rung and ApplyChainUpdates use).
    function test_Std_NoEnv_DeclaredZeroZero_IsDeclaredDisabled() public {
        string memory local = _localChain(7);
        _declareLane(local, "zz-scratch-rlsrc-remote7", _laneEntry(REMOTE_SELECTOR, 0, 0, ""));

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote7", REMOTE_SELECTOR, false);

        _assertOutbound(res.update, true, false, 0, 0);
        assertTrue(res.outboundFromLanes, "declared-disabled still comes from lanes{}");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Standard bucket: rung 3 (neither env vars nor a declared bucket)
    // ─────────────────────────────────────────────────────────────────────────

    // The historical error stands, now naming both remedies (env vars, or the lane declaration).
    function test_Std_NoEnv_NoLane_RevertsNamingBothRemedies() public {
        string memory local = _localChain(8);

        vm.expectRevert(
            bytes(
                string.concat(
                    "At least one direction must be specified: set OUTBOUND_* and/or INBOUND_* rate limit env vars, ",
                    "or declare the lanes.<remote> policy (capacity/rate, optional inbound{}) in project/",
                    local,
                    ".json"
                )
            )
        );
        harness.resolve("zz-scratch-rlsrc-none8", REMOTE_SELECTOR, false);

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fast-finality bucket (the v2.fastFinality axis)
    // ─────────────────────────────────────────────────────────────────────────

    // No env, per-direction declaration: only the declared v2.fastFinality.outbound drives the
    // outbound direction; the undeclared inbound stays untouched. The core fields (deliberately
    // different values) must NOT leak into the fast-finality bucket.
    function test_Ftf_NoEnv_OutboundDeclaredOnly_PerDirection() public {
        string memory local = _localChain(9);
        _declareLane(
            local,
            "zz-scratch-rlsrc-remote9",
            _laneEntry(
                REMOTE_SELECTOR,
                LANE_CAPACITY,
                LANE_RATE,
                _ftfBlock(_ftfDirection("outbound", FTF_CAPACITY, FTF_RATE), "")
            )
        );

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote9", REMOTE_SELECTOR, true);

        _assertOutbound(res.update, true, true, FTF_CAPACITY, FTF_RATE);
        _assertInbound(res.update, false, false, 0, 0);
        assertTrue(res.outboundFromLanes, "outbound must come from v2.fastFinality.outbound");
        assertFalse(res.inboundDeclared, "undeclared fast-finality inbound must stay undeclared");
        assertFalse(res.editHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // No env, both fast-finality directions declared: both driven from the v2 block.
    function test_Ftf_NoEnv_BothDeclared_BothFromLanes() public {
        string memory local = _localChain(10);
        _declareLane(
            local,
            "zz-scratch-rlsrc-remote10",
            _laneEntry(
                REMOTE_SELECTOR,
                LANE_CAPACITY,
                LANE_RATE,
                _ftfBlock(
                    _ftfDirection("outbound", FTF_CAPACITY, FTF_RATE),
                    _ftfDirection("inbound", FTF_INBOUND_CAPACITY, FTF_INBOUND_RATE)
                )
            )
        );

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote10", REMOTE_SELECTOR, true);

        _assertOutbound(res.update, true, true, FTF_CAPACITY, FTF_RATE);
        _assertInbound(res.update, true, true, FTF_INBOUND_CAPACITY, FTF_INBOUND_RATE);
        assertTrue(res.outboundFromLanes && res.inboundFromLanes, "both directions must come from lanes{}");

        _cleanupScratchOne(local);
    }

    // Env set on the fast-finality axis, declared v2.fastFinality.outbound diverges: env wins, the
    // divergence is judged against the FAST-FINALITY declaration, not the (agreeing) core fields.
    function test_Ftf_EnvDivergesFtfDeclaration_AxisScoped() public {
        string memory local = _localChain(11);
        // Core fields deliberately AGREE with the env values; only the fast-finality block differs.
        _declareLane(
            local,
            "zz-scratch-rlsrc-remote11",
            _laneEntry(
                REMOTE_SELECTOR,
                ENV_CAPACITY,
                ENV_RATE,
                _ftfBlock(_ftfDirection("outbound", FTF_CAPACITY, FTF_RATE), "")
            )
        );
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote11", REMOTE_SELECTOR, true);

        _assertOutbound(res.update, true, true, ENV_CAPACITY, ENV_RATE);
        assertEq(res.outboundDeclCapacity, FTF_CAPACITY, "the fast-finality declaration must be consulted");
        assertTrue(res.outboundDiverges, "env override diverging from v2.fastFinality.outbound must be flagged");
        assertTrue(res.editHint, "divergence must hint");

        _cleanupScratchOne(local);
    }

    // Env set on the fast-finality axis with no v2 block declared: env applies, hint armed (the
    // core fields do not count as a declaration for the fast-finality bucket).
    function test_Ftf_EnvOnly_NoV2Block_HintArmed_NoDivergence() public {
        string memory local = _localChain(12);
        _declareLane(local, "zz-scratch-rlsrc-remote12", _laneEntry(REMOTE_SELECTOR, ENV_CAPACITY, ENV_RATE, ""));
        _setOutboundEnv(ENV_CAPACITY, ENV_RATE);

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("zz-scratch-rlsrc-remote12", REMOTE_SELECTOR, true);

        _assertOutbound(res.update, true, true, ENV_CAPACITY, ENV_RATE);
        assertFalse(res.outboundDeclared, "core fields must not count as a fast-finality declaration");
        assertFalse(res.outboundDiverges, "nothing declared, nothing to diverge from");
        assertTrue(res.editHint, "env apply with an undeclared fast-finality bucket must hint");

        _cleanupScratchOne(local);
    }

    // No env and no declared fast-finality bucket (core fields only): the error stands and names
    // the fast-finality declaration path - the axis scoping of rung 3.
    function test_Ftf_NoEnv_CoreOnly_RevertsNamingFtfRemedy() public {
        string memory local = _localChain(13);
        _declareLane(local, "zz-scratch-rlsrc-remote13", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));

        vm.expectRevert(
            bytes(
                string.concat(
                    "At least one direction must be specified: set OUTBOUND_* and/or INBOUND_* rate limit env vars, ",
                    "or declare the lanes.<remote>.v2.fastFinality.{outbound,inbound} bucket(s) in project/",
                    local,
                    ".json"
                )
            )
        );
        harness.resolve("zz-scratch-rlsrc-remote13", REMOTE_SELECTOR, true);

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lane matching: selector fallback
    // ─────────────────────────────────────────────────────────────────────────

    // The lanes key names no config file and differs from the destination name, but the entry's
    // remoteSelector equals the destination selector: the selector fallback matches it.
    function test_SelectorFallback_MatchesWhenKeyNameDiffers() public {
        string memory local = _localChain(14);
        _declareLane(local, "zz-scratch-rlsrc-ghost14", _laneEntry(REMOTE_SELECTOR, LANE_CAPACITY, LANE_RATE, ""));

        UpdateRateLimiters.RateLimitResolution memory res =
            harness.resolve("ZZ_RLSRC_NO_SUCH_ID", REMOTE_SELECTOR, false);

        assertTrue(res.laneFound, "remoteSelector equality must match the entry");
        assertEq(res.laneKey, "zz-scratch-rlsrc-ghost14", "wrong lane key matched");
        _assertOutbound(res.update, true, true, LANE_CAPACITY, LANE_RATE);

        _cleanupScratchOne(local);
    }
}
