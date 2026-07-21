// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SyncCcipConfig} from "../../script/config/SyncCcipConfig.s.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainManualPlaneTest: the `configSource: "manual"` doctor branches (offline)
/// @notice A chain may declare `configSource: "manual"` when a reviewed hand edit, not the API sync,
/// owns its `ccip{}` addresses (an address plane the CCIP REST API does not serve). This suite pins the
/// offline doctor branches that key on that marker:
///   - SCHEMA: `configSource` is OPTIONAL; an absent key reads as `"api"` (no extra schema line, 0/0),
///     an explicit `"api"`/`"manual"` is a known plane (PASS), and any other value is a FAIL (a typo must
///     never silently disable the API drift check).
///   - API: a manual chain SKIPs the drift check (the API is not its writer) and emits exactly one WARN
///     for the residual risk, touching no network.
///   - MESH: a lane whose two endpoints are on DIFFERENT planes (one API, one manual) FAILs, from
///     EITHER side; a same-plane lane (here both manual) still resolves cleanly.
/// @dev Every test owns uniquely-named `config/chains/zz-scratch-manual-*` (chain facts) and their
/// `project/zz-scratch-manual-*.json` (lanes), all `zz-scratch-*` (gitignored) and cleaned in `setUp()`
/// (revert-safe, never at end-of-test). The API-rung branch returns before any fetch, so this whole
/// suite is offline (no ffi, no fork). `FOUNDRY_PROFILE=sync` satisfies the `addLane` entrypoint guard.
contract VerifyChainManualPlaneTest is Test {
    uint256 internal constant CAPACITY = 100_000e18;
    uint256 internal constant RATE = 100e18;

    string internal constant SCH_MANUAL = "zz-scratch-manual-schema-manual";
    string internal constant SCH_API = "zz-scratch-manual-schema-api";
    string internal constant SCH_BOGUS = "zz-scratch-manual-schema-bogus";
    string internal constant SCH_ABSENT = "zz-scratch-manual-schema-absent";
    string internal constant API_MANUAL = "zz-scratch-manual-apirung";
    string internal constant XPLANE_API = "zz-scratch-manual-xplane-api";
    string internal constant XPLANE_MAN = "zz-scratch-manual-xplane-man";
    string internal constant SAME_MAN_A = "zz-scratch-manual-same-a";
    string internal constant SAME_MAN_B = "zz-scratch-manual-same-b";
    string internal constant SYNC_TYPO = "zz-scratch-manual-synctypo";

    SyncCcipConfig internal sync;

    function setUp() public {
        _clean();
        vm.setEnv("FOUNDRY_PROFILE", "sync");
        sync = new SyncCcipConfig();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp() (revert-safe: a failed test leaves its
    /// fixtures for inspection until the next run). Each test additionally removes ONLY the fixtures it
    /// owns at the end of its body (suite siblings run in parallel), so a green run leaves no residue.
    function _clean() private {
        string[10] memory names = [
            SCH_MANUAL,
            SCH_API,
            SCH_BOGUS,
            SCH_ABSENT,
            API_MANUAL,
            XPLANE_API,
            XPLANE_MAN,
            SAME_MAN_A,
            SAME_MAN_B,
            SYNC_TYPO
        ];
        for (uint256 i = 0; i < names.length; i++) {
            _cleanAll(names[i]);
        }
    }

    function _cleanAll(string memory name) internal {
        string memory cfg = _path(name);
        if (vm.exists(cfg)) vm.removeFile(cfg);
        string memory proj = ProjectStore._path(name);
        if (vm.exists(proj)) vm.removeFile(proj);
    }

    function _path(string memory name) internal pure returns (string memory) {
        return string.concat("config/chains/", name, ".json");
    }

    /// @dev Writes a complete scratch EVM chain config (every schema key, NO lanes/roles/ccipBnM). A
    /// non-empty `configSource` adds that top-level key; "" omits it (today's default = "api").
    function _writeChain(string memory name, uint256 chainId, uint64 selector, string memory configSource) internal {
        string memory obj = string.concat("mp-", name);
        vm.serializeString(obj, "name", name);
        vm.serializeString(obj, "displayName", string.concat("Scratch ", name));
        vm.serializeString(obj, "chainNameIdentifier", "ZZ_SCRATCH_MANUAL");
        vm.serializeString(obj, "chainFamily", "evm");
        vm.serializeString(obj, "environment", "testnet");
        vm.serializeString(obj, "chainId", vm.toString(chainId));
        vm.serializeString(obj, "chainSelector", vm.toString(selector));
        vm.serializeString(obj, "rpcEnv", "ZZ_SCRATCH_MANUAL_RPC_URL");
        vm.serializeString(obj, "explorerUrl", "https://example.invalid");
        vm.serializeString(obj, "nativeCurrencySymbol", "ZZZ");
        if (bytes(configSource).length != 0) {
            vm.serializeString(obj, "configSource", configSource);
        }
        string memory ccipObj = string.concat("mp-ccip-", name);
        vm.serializeAddress(ccipObj, "router", address(2));
        vm.serializeAddress(ccipObj, "rmnProxy", address(3));
        vm.serializeAddress(ccipObj, "tokenAdminRegistry", address(5));
        vm.serializeAddress(ccipObj, "registryModuleOwnerCustom", address(4));
        vm.serializeAddress(ccipObj, "link", address(1));
        vm.serializeAddress(ccipObj, "feeQuoter", address(6));
        vm.serializeAddress(ccipObj, "tokenPoolFactory", address(7));
        string memory ccipJson = vm.serializeAddress(ccipObj, "feeTokens", new address[](0));
        vm.writeFile(_path(name), vm.serializeString(obj, "ccip", ccipJson));
    }

    // ---------------------------------------------------------------- schema rung

    /// @dev `configSource: "manual"` is a KNOWN plane: the schema rung PASSes it (0 FAIL, 0 WARN),
    /// exactly like a complete config, so the manual marker never trips the schema check.
    function test_SchemaRung_Manual_Pass() public {
        _writeChain(SCH_MANUAL, 889_400_001, 8_894_000_010_000_000_001, "manual");
        (bool isEvm, uint256 fails, uint256 warns) = new VerifyChain().checkSchemaForTest(SCH_MANUAL);
        assertTrue(isEvm, "manual scratch config is EVM");
        assertEq(fails, 0, "configSource 'manual' is a known plane - schema rung must PASS");
        assertEq(warns, 0, "the schema rung emits no WARNs");
        _cleanAll(SCH_MANUAL);
    }

    /// @dev An explicit `configSource: "api"` is also a known plane (the same value the absent key
    /// defaults to) and PASSes the schema rung.
    function test_SchemaRung_ApiExplicit_Pass() public {
        _writeChain(SCH_API, 889_400_002, 8_894_000_020_000_000_001, "api");
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SCH_API);
        assertEq(fails, 0, "configSource 'api' is a known plane - schema rung must PASS");
        _cleanAll(SCH_API);
    }

    /// @dev A configSource that is neither "api" nor "manual" is a FAIL: a typo must never silently
    /// disable the API drift check by making the chain look like an unknown-but-tolerated plane.
    function test_SchemaRung_UnknownPlane_Fail() public {
        _writeChain(SCH_BOGUS, 889_400_003, 8_894_000_030_000_000_001, "handwritten");
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SCH_BOGUS);
        assertGt(fails, 0, "an unknown configSource value must FAIL the schema rung");
        _cleanAll(SCH_BOGUS);
    }

    /// @dev NON-REGRESSION: a config with NO configSource key emits no configSource schema line and stays
    /// 0 FAIL / 0 WARN (an absent key reads as `"api"`; the offline sync no-op + fmt-config gates prove
    /// the write path leaves such a config byte-identical too).
    function test_SchemaRung_Absent_NonRegression() public {
        _writeChain(SCH_ABSENT, 889_400_004, 8_894_000_040_000_000_001, "");
        string memory json = vm.readFile(_path(SCH_ABSENT));
        assertFalse(vm.keyExistsJson(json, ".configSource"), "precondition: config carries NO configSource key");
        (, uint256 fails, uint256 warns) = new VerifyChain().checkSchemaForTest(SCH_ABSENT);
        assertEq(fails, 0, "a config without configSource must PASS the schema rung (unchanged)");
        assertEq(warns, 0, "a config without configSource emits no WARN (unchanged)");
        _cleanAll(SCH_ABSENT);
    }

    // ---------------------------------------------------------------- sync fail-closed

    /// @dev FAIL-CLOSED: a present-but-unknown configSource value makes the SYNC refuse (revert) rather
    /// than fall back to `"api"` and overwrite the addresses. `run()` reverts in the manual guard before
    /// any API fetch, so a plain `SyncCcipConfig` exercises it offline. This is the no-overwrite guarantee
    /// for a typo'd marker (a capital `"Manual"` here, which is NOT the exact `"manual"` value).
    function test_Sync_UnknownConfigSource_Refuses() public {
        _writeChain(SYNC_TYPO, 889_400_010, 8_894_000_100_000_000_001, "Manual");
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                string.concat(
                    "[sync] ",
                    SYNC_TYPO,
                    " has an unknown configSource \"Manual\" - use \"api\" or \"manual\"; refusing to sync so the addresses are not overwritten"
                )
            )
        );
        sync.run(SYNC_TYPO);
        _cleanAll(SYNC_TYPO);
    }

    // ---------------------------------------------------------------- api rung

    /// @dev A manual chain SKIPs the API drift check and emits exactly ONE WARN (the residual risk that
    /// an address change to this plane is not API-detectable), with NO FAIL and no network call. The
    /// branch returns before any fetch, which is why this assertion runs offline.
    function test_ApiRung_Manual_SkipsAndWarns() public {
        _writeChain(API_MANUAL, 889_400_005, 8_894_000_050_000_000_001, "manual");
        (uint256 fails, uint256 warns) = new VerifyChain().checkApiForTest(API_MANUAL);
        assertEq(fails, 0, "a manual chain's API rung never FAILs (the API is not its writer)");
        assertEq(warns, 1, "a manual chain's API rung emits exactly one WARN for the residual risk");
        _cleanAll(API_MANUAL);
    }

    // ---------------------------------------------------------------- mesh rung

    /// @dev CROSS-PLANE FAIL from EITHER side: a lane between an API-sourced chain and a manual chain is
    /// refused by the doctor. `add-lane` refuses a cross-plane lane at creation, so a cross-plane lane
    /// can only arise by converting one endpoint's plane AFTER the lanes exist, modeled here by building
    /// a same-plane reciprocal mesh, then flipping one config to manual. The mesh rung then FAILs when
    /// doctoring either endpoint (each checks its own declared lanes).
    function test_MeshRung_CrossPlaneLane_FailsFromEitherSide() public {
        _writeChain(XPLANE_API, 889_400_006, 8_894_000_060_000_000_001, "");
        _writeChain(XPLANE_MAN, 889_400_007, 8_894_000_070_000_000_001, "");
        // Reciprocal, same-plane (both API) lanes: allowed at creation, and clean before the flip.
        sync.addLane(XPLANE_API, XPLANE_MAN, CAPACITY, RATE);
        sync.addLane(XPLANE_MAN, XPLANE_API, CAPACITY, RATE);
        (uint256 fPre,) = new VerifyChain().checkMeshForTest(XPLANE_API);
        assertEq(fPre, 0, "a same-plane reciprocal mesh is clean before any plane flip");

        // Convert one endpoint to a manual plane (config-file edit only; the project store is untouched,
        // so the lanes survive) - now the declared lanes straddle two planes.
        _writeChain(XPLANE_MAN, 889_400_007, 8_894_000_070_000_000_001, "manual");
        (uint256 fApiSide,) = new VerifyChain().checkMeshForTest(XPLANE_API);
        (uint256 fManSide,) = new VerifyChain().checkMeshForTest(XPLANE_MAN);
        assertEq(fApiSide, 1, "doctoring the API side FAILs on the cross-plane lane");
        assertEq(fManSide, 1, "doctoring the manual side FAILs on the cross-plane lane");
        _cleanAll(XPLANE_API);
        _cleanAll(XPLANE_MAN);
    }

    /// @dev SAME-PLANE (both manual) lane is fully supported: a reciprocal lane between two manual-plane
    /// chains resolves cleanly (0 FAIL), so a hand-maintained plane is not crippled - only cross-plane is.
    function test_MeshRung_SamePlaneManualLane_Passes() public {
        _writeChain(SAME_MAN_A, 889_400_008, 8_894_000_080_000_000_001, "manual");
        _writeChain(SAME_MAN_B, 889_400_009, 8_894_000_090_000_000_001, "manual");
        sync.addLane(SAME_MAN_A, SAME_MAN_B, CAPACITY, RATE);
        sync.addLane(SAME_MAN_B, SAME_MAN_A, CAPACITY, RATE);
        (uint256 fails,) = new VerifyChain().checkMeshForTest(SAME_MAN_A);
        assertEq(fails, 0, "a same-plane (both manual) reciprocal lane must resolve cleanly");
        _cleanAll(SAME_MAN_A);
        _cleanAll(SAME_MAN_B);
    }
}
