// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts@5.3.0/utils/Strings.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {UpdateCCVConfig} from "../../script/configure/ccv/UpdateCCVConfig.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev A 1.5.0 read surface: only typeAndVersion. The CCV setters are 2.0.0-only, so the version
///      fence must refuse this pool by name before any hooks read.
contract MockCcv150Pool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.5.0";
    }
}

/// @dev A 2.0.0 pool that answers the version fence but has NO advanced hooks wired (address(0)):
///      the setter must refuse by name (CCV config lives on the hooks contract).
contract MockCcvV2NoHooksPool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.0.0";
    }

    function getAdvancedPoolHooks() external pure returns (address) {
        return address(0);
    }
}

/// @dev Exposes UpdateCCVConfig's array/threshold input resolution and the call builder with the env
///      access swapped for an injectable fake (the `_env*` seams exist for exactly this - env vars
///      are process-global and forge runs suites in parallel, so tests must never vm.setEnv shared
///      names). The current on-chain config is a parameter because run() reads it from the hooks
///      contract before resolving; the rung-3 read-modify-write fallback needs no fork to trust.
contract CCVConfigLaneSourceHarness is UpdateCCVConfig {
    mapping(bytes32 => string) private fakeEnv;

    function setFakeEnv(string memory name, string memory value) external {
        fakeEnv[keccak256(bytes(name))] = value;
    }

    function _envExists(string memory name) internal view override returns (bool) {
        return bytes(fakeEnv[keccak256(bytes(name))]).length != 0;
    }

    function _envString(string memory name) internal view override returns (string memory) {
        return fakeEnv[keccak256(bytes(name))];
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? 0 : vm.parseUint(value);
    }

    function resolve(
        AdvancedPoolHooks.CCVConfig memory current,
        uint256 currentThreshold,
        string memory destChainName,
        uint64 destChainSelector
    ) external view returns (CCVConfigResolution memory) {
        return _resolveCCVConfig(current, currentThreshold, destChainName, destChainSelector);
    }

    function build(CCVConfigResolution memory res, uint64 destChainSelector)
        external
        pure
        returns (AdvancedPoolHooks.CCVConfigArg[] memory)
    {
        return _buildCCVArgs(res, destChainSelector);
    }

    function fencedHooks(address pool, bool haveLane) external view returns (address) {
        return _fencedHooks(pool, haveLane);
    }
}

/// @notice The per-array CCV input ladder of UpdateCCVConfig (env > declared `lanes.<remote>.v2.ccv.<field>`
///         > current on-chain value), proven offline against scratch chain configs. Centres on the
///         READ-MODIFY-WRITE guarantee: `applyCCVConfigUpdates` fully replaces a chain's entry, so an
///         undeclared array MUST carry its current on-chain value into the built call, never an empty
///         one. Also covers env byte-equality, lanes{} consumption, the pool-global threshold ladder,
///         the SET-insensitive divergence notice + hand-edit hint (byte-exact), the semantic-rule named
///         requires, and the two version/hooks fences. Each test pins block.chainid to its own scratch
///         chain via vm.chainId (test-local, no process-global state).
contract UpdateCCVConfigLaneSourceTest is LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_874_000_000_000_000_001;

    // Disjoint CCV addresses so every assertion proves its source rung unambiguously:
    // E* = env, LANE* = declared in lanes{}, CUR* = current on-chain.
    address internal constant E1 = address(0xE001);
    address internal constant CUR1 = address(0xC001);
    address internal constant CUR2 = address(0xC002);
    address internal constant LANE1 = address(0xA001);
    address internal constant LANE2 = address(0xA002);

    CCVConfigLaneSourceHarness internal harness;

    function setUp() public {
        _clean();
        harness = new CCVConfigLaneSourceHarness();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](10);
        for (uint256 n = 1; n <= 10; n++) {
            names[n - 1] = string.concat("zz-scratch-ccvsrc-l", vm.toString(n));
        }
        _cleanupScratch(names);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _localChain(uint256 n) internal returns (string memory name) {
        name = string.concat("zz-scratch-ccvsrc-l", vm.toString(n));
        uint256 chainId = 887_400_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_874_010_000_000_000_000 + n * 100 + 1));
        vm.chainId(chainId);
    }

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _arr2(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @dev A current on-chain config with all four arrays populated (the RMW baseline).
    function _current() internal pure returns (AdvancedPoolHooks.CCVConfig memory c) {
        c.outboundCCVs = _arr(CUR1);
        c.thresholdOutboundCCVs = new address[](0);
        c.inboundCCVs = _arr(CUR2);
        c.thresholdInboundCCVs = new address[](0);
    }

    // ── RMW: the centrepiece ────────────────────────────────────────────────────

    /// Declaring/env-setting ONLY outboundCCVs must NOT wipe the other three arrays: the built
    /// CCVConfigArg carries the current on-chain inbound (and empty threshold) arrays unchanged.
    function test_RMW_EnvOnlyOutbound_CarriesCurrentOtherArrays() public {
        string memory name = _localChain(1);
        harness.setFakeEnv("OUTBOUND_CCVS", vm.toString(E1));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-remote", REMOTE_SELECTOR);
        AdvancedPoolHooks.CCVConfigArg[] memory args = harness.build(res, REMOTE_SELECTOR);

        assertEq(args[0].outboundCCVs.length, 1, "outbound from env");
        assertEq(args[0].outboundCCVs[0], E1, "outbound is the env value");
        // The untouched arrays carry the CURRENT on-chain values, not empty.
        assertEq(args[0].inboundCCVs.length, 1, "inbound preserved (RMW)");
        assertEq(args[0].inboundCCVs[0], CUR2, "inbound is the current on-chain value");
        assertEq(args[0].thresholdOutboundCCVs.length, 0, "threshold-out preserved");
        assertEq(args[0].thresholdInboundCCVs.length, 0, "threshold-in preserved");

        _cleanupScratchOne(name);
    }

    /// Changing only the CCV arrays leaves the pool-global threshold untouched (not written to 0).
    function test_RMW_NoThresholdEnv_PreservesCurrentThreshold() public {
        string memory name = _localChain(2);
        harness.setFakeEnv("OUTBOUND_CCVS", vm.toString(E1));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 1000, "zz-scratch-ccvsrc-remote", REMOTE_SELECTOR);

        assertFalse(res.threshold.fromEnv, "threshold not from env");
        assertFalse(res.threshold.fromLanes, "threshold not from lanes");
        assertEq(res.threshold.value, 1000, "threshold carries the current on-chain value");

        _cleanupScratchOne(name);
    }

    // ── ladder rungs ────────────────────────────────────────────────────────────

    function test_Rung2_LanesOnly_ArraysFromDeclaration() public {
        string memory local = _localChain(3);
        // declare a v2.ccv block on a scratch remote lane
        string memory ccv = string.concat(
            ",\"v2\":{\"ccv\":{\"outboundCCVs\":[\"",
            vm.toString(LANE1),
            "\"],\"inboundCCVs\":[\"",
            vm.toString(LANE2),
            "\"]}}"
        );
        _declareLane(local, "zz-scratch-ccvsrc-r3", _laneEntry(REMOTE_SELECTOR, 1000e18, 100e18, ccv));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-r3", REMOTE_SELECTOR);

        assertTrue(res.laneFound, "lane matched");
        assertTrue(res.blockDeclared, "v2.ccv block declared");
        assertTrue(res.fields[0].fromLanes, "outbound from lanes");
        assertEq(res.fields[0].value[0], LANE1, "outbound is the declared value");
        assertEq(res.fields[2].value[0], LANE2, "inbound is the declared value");
        assertFalse(res.editHint, "lanes-sourced apply does not hint");

        _cleanupScratchOne(local);
    }

    /// Env override diverging (as a SET) from the declaration fires the notice + hand-edit hint,
    /// pinned byte-exact.
    function test_Rung1_EnvDivergesFromDeclaration_NoticeAndHint() public {
        string memory local = _localChain(4);
        string memory ccv = string.concat(",\"v2\":{\"ccv\":{\"outboundCCVs\":[\"", vm.toString(LANE1), "\"]}}");
        _declareLane(local, "zz-scratch-ccvsrc-r4", _laneEntry(REMOTE_SELECTOR, 1000e18, 100e18, ccv));
        harness.setFakeEnv("OUTBOUND_CCVS", vm.toString(E1)); // diverges from declared LANE1

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-r4", REMOTE_SELECTOR);

        assertTrue(res.fields[0].diverges, "env outbound diverges from declaration");
        assertTrue(res.editHint, "diverging env apply must hint");
        assertEq(
            res.fieldNotices[0],
            string.concat(
                unicode"⚠️  OUTBOUND_CCVS=[",
                vm.toString(E1),
                "] diverges from declared lanes.zz-scratch-ccvsrc-r4.v2.ccv.outboundCCVs=[",
                vm.toString(LANE1),
                "] in project/",
                local,
                ".json - make doctor will FAIL until reconciled"
            ),
            "composed CCV divergence notice"
        );
        // Byte-exact pin of the composed closing hand-edit hint (DIVERGING-from-declaration variant).
        // Undeclared arrays carry their current on-chain values into the applied-values echo (RMW).
        assertEq(
            res.editHintText,
            string.concat(
                unicode"⚠️  Applied CCV config is diverging from lanes.zz-scratch-ccvsrc-r4.v2.ccv (project/",
                local,
                ".json). Hand-edit the block to the applied values: outboundCCVs=[",
                vm.toString(E1),
                "] thresholdOutboundCCVs=[] inboundCCVs=[",
                vm.toString(CUR2),
                "] thresholdInboundCCVs=[] - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed diverging edit hint"
        );

        _cleanupScratchOne(local);
    }

    /// Env-driven apply against a lane whose `v2.ccv` block is UNDECLARED fires the "not declared in"
    /// hand-edit hint (byte-exact). The undeclared arrays carry their current on-chain values (RMW).
    function test_Rung1_EnvUndeclaredBlock_NotDeclaredHint() public {
        string memory local = _localChain(7);
        // A core-only lane entry (no v2.ccv block) -> blockDeclared is false.
        _declareLane(local, "zz-scratch-ccvsrc-r7", _laneEntry(REMOTE_SELECTOR, 1000e18, 100e18, ""));
        harness.setFakeEnv("OUTBOUND_CCVS", vm.toString(E1));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-r7", REMOTE_SELECTOR);

        assertTrue(res.laneFound, "lane matched");
        assertFalse(res.blockDeclared, "no v2.ccv block declared");
        assertTrue(res.editHint, "env apply with an undeclared block must hint");
        assertEq(
            res.editHintText,
            string.concat(
                unicode"⚠️  Applied CCV config is not declared in lanes.zz-scratch-ccvsrc-r7.v2.ccv (project/",
                local,
                ".json). Hand-edit the block to the applied values: outboundCCVs=[",
                vm.toString(E1),
                "] thresholdOutboundCCVs=[] inboundCCVs=[",
                vm.toString(CUR2),
                "] thresholdInboundCCVs=[] - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed not-declared edit hint"
        );

        _cleanupScratchOne(local);
    }

    /// Inbound-only RMW mirror of the outbound centrepiece: env-setting ONLY inboundCCVs must NOT wipe
    /// the other three arrays; the built CCVConfigArg carries the current outbound array unchanged.
    function test_RMW_EnvOnlyInbound_CarriesCurrentOtherArrays() public {
        string memory name = _localChain(8);
        harness.setFakeEnv("INBOUND_CCVS", vm.toString(E1));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-remote", REMOTE_SELECTOR);
        AdvancedPoolHooks.CCVConfigArg[] memory args = harness.build(res, REMOTE_SELECTOR);

        assertEq(args[0].inboundCCVs.length, 1, "inbound from env");
        assertEq(args[0].inboundCCVs[0], E1, "inbound is the env value");
        assertEq(args[0].outboundCCVs.length, 1, "outbound preserved (RMW)");
        assertEq(args[0].outboundCCVs[0], CUR1, "outbound is the current on-chain value");
        assertEq(args[0].thresholdOutboundCCVs.length, 0, "threshold-out preserved");
        assertEq(args[0].thresholdInboundCCVs.length, 0, "threshold-in preserved");

        _cleanupScratchOne(name);
    }

    /// Threshold rung 2: a declared `poolPolicy.ccvThreshold` with no env var resolves from the
    /// project store (fromLanes), not from env, and does not arm the threshold hand-edit hint.
    function test_Threshold_DeclaredOnly_FromPoolPolicy() public {
        string memory local = _localChain(9);
        _declarePoolPolicy(local, "{\"ccvThreshold\":\"750\"}");

        UpdateCCVConfig.CCVConfigResolution memory res = harness.resolve(_current(), 100, "", 0);

        assertFalse(res.threshold.fromEnv, "threshold not from env");
        assertTrue(res.threshold.fromLanes, "threshold from declared poolPolicy.ccvThreshold");
        assertEq(res.threshold.value, 750, "threshold is the declared value");
        assertFalse(res.thresholdHint, "a declared-sourced threshold does not hint");

        _cleanupScratchOne(local);
    }

    /// A ccvThreshold left at the top level of config/chains is NOT a declaration: the ladder reads
    /// only poolPolicy.ccvThreshold in the project store, so the stray key is ignored and the
    /// current on-chain value carries (the doctor's schema rung FAILs the stray key by name).
    function test_Threshold_StrayConfigKey_Ignored() public {
        string memory local = _localChain(10);
        vm.writeJson("750", _path(local), ".ccvThreshold"); // stray hand edit in the config file

        UpdateCCVConfig.CCVConfigResolution memory res = harness.resolve(_current(), 100, "", 0);

        assertFalse(res.threshold.fromEnv, "threshold not from env");
        assertFalse(res.threshold.fromLanes, "a stray config-file ccvThreshold is not a declaration");
        assertEq(res.threshold.value, 100, "the current on-chain value carries");

        _cleanupScratchOne(local);
    }

    /// Env that agrees with the declaration as a SET (same members, different order) does not diverge.
    function test_Rung1_EnvAgreesAsSet_NoDivergence() public {
        string memory local = _localChain(5);
        string memory ccv = string.concat(
            ",\"v2\":{\"ccv\":{\"outboundCCVs\":[\"", vm.toString(LANE1), "\",\"", vm.toString(LANE2), "\"]}}"
        );
        _declareLane(local, "zz-scratch-ccvsrc-r5", _laneEntry(REMOTE_SELECTOR, 1000e18, 100e18, ccv));
        // env lists the same two, reversed order
        harness.setFakeEnv("OUTBOUND_CCVS", string.concat(vm.toString(LANE2), ",", vm.toString(LANE1)));

        UpdateCCVConfig.CCVConfigResolution memory res =
            harness.resolve(_current(), 0, "zz-scratch-ccvsrc-r5", REMOTE_SELECTOR);

        assertFalse(res.fields[0].diverges, "same set in a different order is not drift");

        _cleanupScratchOne(local);
    }

    function test_Threshold_EnvDivergesFromDeclared_Hint() public {
        string memory local = _localChain(6);
        // poolPolicy.ccvThreshold declared = 500, env = 900
        _declarePoolPolicy(local, "{\"ccvThreshold\":\"500\"}");
        harness.setFakeEnv("CCV_THRESHOLD_AMOUNT", "900");

        UpdateCCVConfig.CCVConfigResolution memory res = harness.resolve(_current(), 100, "", 0);

        assertTrue(res.threshold.fromEnv, "threshold from env");
        assertTrue(res.threshold.diverges, "env threshold diverges from declared");
        assertEq(res.threshold.value, 900, "env threshold wins");
        assertTrue(res.thresholdHint, "diverging threshold hints");
        // Byte-exact pin of the composed threshold divergence notice and closing hand-edit hint.
        assertEq(
            res.thresholdNotice,
            string.concat(
                unicode"⚠️  CCV_THRESHOLD_AMOUNT=900 diverges from declared poolPolicy.ccvThreshold=500 in project/",
                local,
                ".json - make doctor will FAIL until reconciled"
            ),
            "composed threshold divergence notice"
        );
        assertEq(
            res.thresholdHintText,
            string.concat(
                unicode"⚠️  Applied CCV threshold 900 is diverging from poolPolicy.ccvThreshold in project/",
                local,
                ".json - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed threshold edit hint"
        );

        _cleanupScratchOne(local);
    }

    // ── semantic-rule named requires ────────────────────────────────────────────

    function test_Build_ThresholdWithoutBase_RevertsByName() public {
        UpdateCCVConfig.CCVConfigResolution memory res;
        res.fields[0].value = new address[](0); // outbound empty
        res.fields[1].value = _arr(E1); // thresholdOutbound non-empty -> illegal
        res.fields[2].value = new address[](0);
        res.fields[3].value = new address[](0);

        vm.expectRevert(
            bytes(
                "CCV outbound threshold list is non-empty but the base outboundCCVs list is empty; a threshold list requires a non-empty base list (specify address(0) to use the defaults below the threshold)"
            )
        );
        harness.build(res, REMOTE_SELECTOR);
    }

    function test_Build_SharedBetweenBaseAndThreshold_RevertsByName() public {
        UpdateCCVConfig.CCVConfigResolution memory res;
        res.fields[0].value = _arr(E1); // outbound base [E1]
        res.fields[1].value = _arr(E1); // thresholdOutbound [E1] -> shared with the base -> illegal
        res.fields[2].value = new address[](0);
        res.fields[3].value = new address[](0);

        vm.expectRevert(
            bytes(
                string.concat(
                    "CCV outbound address ",
                    vm.toString(E1),
                    " appears in both the base and the threshold list; an address must not be shared between a list and its threshold list"
                )
            )
        );
        harness.build(res, REMOTE_SELECTOR);
    }

    function test_Build_DuplicateInList_RevertsByName() public {
        UpdateCCVConfig.CCVConfigResolution memory res;
        res.fields[0].value = _arr2(E1, E1); // duplicate
        res.fields[1].value = new address[](0);
        res.fields[2].value = new address[](0);
        res.fields[3].value = new address[](0);

        vm.expectRevert(
            bytes(
                string.concat(
                    "CCV field outboundCCVs contains a duplicate address ",
                    vm.toString(E1),
                    "; remove the duplicate (the hooks contract rejects duplicates)"
                )
            )
        );
        harness.build(res, REMOTE_SELECTOR);
    }

    // ── version + hooks fences ──────────────────────────────────────────────────

    function test_Fence_Pre200Pool_NamedRefusal() public {
        MockCcv150Pool pool = new MockCcv150Pool();
        // requireSupports renders the pool via OZ Strings.toHexString (lowercase), unlike the
        // no-hooks require below which uses vm.toString (checksummed).
        vm.expectRevert(
            bytes(
                string.concat(
                    "UnsupportedPoolOperation: applyCCVConfigUpdates is not available on pool ",
                    Strings.toHexString(address(pool)),
                    " (contract version 1.5.0). The operation exists on pool versions 2.0.0 and later. See docs/pool-versions.md#operation-ranges; the capability table lives in src/PoolVersions.sol."
                )
            )
        );
        harness.fencedHooks(address(pool), true);
    }

    function test_Fence_V2NoHooks_NamedRefusal() public {
        MockCcvV2NoHooksPool pool = new MockCcvV2NoHooksPool();
        vm.expectRevert(
            bytes(
                string.concat(
                    "No AdvancedPoolHooks wired to pool ",
                    vm.toString(address(pool)),
                    " - CCV config lives on the hooks contract. Deploy one (script/configure/allowlist/DeployAdvancedPoolHooks.s.sol) and wire it (script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol, NEW_HOOK=<addr>) before configuring CCVs."
                )
            )
        );
        harness.fencedHooks(address(pool), true);
    }
}
