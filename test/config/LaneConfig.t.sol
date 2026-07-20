// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SyncCcipConfig} from "../../script/config/SyncCcipConfig.s.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {IConfigSource} from "../../src/config/IConfigSource.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @dev Offline stand-in for `CcipApiSource` behind the `IConfigSource` seam: returns a pre-built
/// flat JSON (the shape `ccip-config-source.sh` emits) so a real `SyncCcipConfig.run` can execute
/// in a test with no ffi / network.
contract StubConfigSource is IConfigSource {
    string private flat;

    constructor(string memory flatJson) {
        flat = flatJson;
    }

    function fetchActiveCcipConfig(uint64) external view returns (string memory) {
        return flat;
    }
}

/// @dev `SyncCcipConfig` with the config source swapped for the offline stub (the seam's stated
/// purpose: "a local snapshot for offline testing" is a one-override change).
contract SyncHarness is SyncCcipConfig {
    IConfigSource private stub;

    function setSource(IConfigSource source) external {
        stub = source;
    }

    function _source() internal view override returns (IConfigSource) {
        return stub;
    }
}

/// @title LaneConfigTest
/// @notice The `lanes{}` policy-subtree contracts: lanes live in the gitignored
/// `project/<selectorName>.json` (NOT `config/chains`, which is pure API/chain facts):
///   - PRESERVATION: a `lanes` entry survives a `ccip` sync (the sync writes only `.ccip` in the config
///     file and never touches the project file), and an `addLane` write touches ONLY the project file's
///     `.lanes` subtree (addresses/roles/schema byte-identical).
///   - GUARDS: a duplicate lane is a logged no-op leaving the project file byte-identical; a self-lane
///     (same name, or two configs sharing one chainSelector) is refused before any write.
///   - RECIPROCITY: an induced one-sided lane FAILs the doctor's mesh rung from EITHER side, and
///     adding the reciprocal entry clears it.
/// @dev Every test owns uniquely-named scratch chains under `config/chains/zz-scratch-lane-*` (chain
/// facts) and their `project/zz-scratch-lane-*.json` (lanes), all `zz-scratch-*` (gitignored) and
/// cleaned in `setUp()` (revert-safe, never at end-of-test). `FOUNDRY_PROFILE=sync` satisfies the
/// entrypoint guard (no ffi is used by `addLane`).
contract LaneConfigTest is Test {
    uint256 internal constant CAPACITY = 100_000e18;
    uint256 internal constant RATE = 100e18;

    SyncCcipConfig internal sync;

    function setUp() public {
        _clean();
        vm.setEnv("FOUNDRY_PROFILE", "sync");
        sync = new SyncCcipConfig();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[2] memory prefixes = ["zz-scratch-lane-a", "zz-scratch-lane-b"];
        for (uint256 p = 0; p < prefixes.length; p++) {
            for (uint256 n = 1; n <= 11; n++) {
                _cleanAll(string.concat(prefixes[p], vm.toString(n)));
            }
        }
        string[5] memory extras = [
            "zz-scratch-lane-c1", "zz-scratch-lane-c6", "zz-scratch-lane-c7", "zz-scratch-lane-c8", "zz-scratch-lane-c9"
        ];
        for (uint256 i = 0; i < extras.length; i++) {
            _cleanAll(extras[i]);
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

    function _projPath(string memory name) internal view returns (string memory) {
        return ProjectStore._path(name);
    }

    /// @dev Writes a scratch chain config in the committed shape (all API/chain-fact schema keys -
    /// NO `lanes`/`roles`/`ccipBnM`, which live in `project/`), keyed by a fake-but-valid
    /// chainId/selector no other test uses.
    function _writeScratchChain(string memory name, uint256 chainId, uint64 selector) internal {
        string memory obj = string.concat("scratch-", name);
        vm.serializeString(obj, "name", name);
        vm.serializeString(obj, "displayName", string.concat("Scratch ", name));
        vm.serializeString(obj, "chainNameIdentifier", "ZZ_SCRATCH_LANE");
        vm.serializeString(obj, "chainFamily", "evm");
        vm.serializeString(obj, "environment", "testnet");
        vm.serializeString(obj, "chainId", vm.toString(chainId));
        vm.serializeString(obj, "chainSelector", vm.toString(selector));
        vm.serializeString(obj, "rpcEnv", "ZZ_SCRATCH_LANE_RPC_URL");
        vm.serializeString(obj, "explorerUrl", "https://example.invalid");
        vm.serializeString(obj, "nativeCurrencySymbol", "ZZZ");
        string memory ccipObj = string.concat("scratch-ccip-", name);
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

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /// @dev keccak of a subtree's parsed (abi-encoded) value: stable under key-order changes, so it
    /// compares CONTENT, not formatting.
    function _subtreeHash(string memory json, string memory key) internal pure returns (bytes32) {
        return keccak256(vm.parseJson(json, string.concat(".", key)));
    }

    function test_AddLane_WritesOnlyLanesSubtree() public {
        _writeScratchChain("zz-scratch-lane-a1", 888000101, 8880001010000000001);
        _writeScratchChain("zz-scratch-lane-b1", 888000102, 8880001020000000002);
        _writeScratchChain("zz-scratch-lane-c1", 888000103, 8880001030000000003);

        // First touch seeds the project skeleton and writes the first lane; capture that as `before`.
        sync.addLane("zz-scratch-lane-a1", "zz-scratch-lane-b1", CAPACITY, RATE);
        string memory before = vm.readFile(_projPath("zz-scratch-lane-a1"));
        bytes32 configBefore = keccak256(bytes(vm.readFile(_path("zz-scratch-lane-a1"))));

        // A second lane rewrites `.lanes` only - addresses/roles/schema must be content-identical.
        sync.addLane("zz-scratch-lane-a1", "zz-scratch-lane-c1", CAPACITY, RATE);
        string memory after_ = vm.readFile(_projPath("zz-scratch-lane-a1"));

        string[] memory keys = vm.parseJsonKeys(before, ".");
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes("lanes"))) continue;
            assertEq(
                _subtreeHash(before, keys[i]),
                _subtreeHash(after_, keys[i]),
                string.concat("add-lane mutated project .", keys[i])
            );
        }
        // The new entry carries the policy + the remote's selector.
        assertEq(
            vm.parseJsonString(after_, ".lanes.zz-scratch-lane-b1.capacity"), vm.toString(CAPACITY), "lane capacity"
        );
        assertEq(vm.parseJsonString(after_, ".lanes.zz-scratch-lane-b1.rate"), vm.toString(RATE), "lane rate");
        assertEq(
            vm.parseJsonString(after_, ".lanes.zz-scratch-lane-b1.remoteSelector"),
            "8880001020000000002",
            "lane remoteSelector"
        );
        // The config file (pure chain facts) is NEVER touched by add-lane.
        assertEq(
            keccak256(bytes(vm.readFile(_path("zz-scratch-lane-a1")))),
            configBefore,
            "add-lane touched the config/chains file"
        );
        // The remote's project file is not created by a local add-lane (declaration is one-sided).
        assertFalse(vm.exists(_projPath("zz-scratch-lane-b1")), "add-lane created the remote project file");
        _cleanAll("zz-scratch-lane-a1");
        _cleanAll("zz-scratch-lane-b1");
        _cleanAll("zz-scratch-lane-c1");
    }

    function test_AddLane_IdenticalReRunIsByteIdenticalNoOp() public {
        _writeScratchChain("zz-scratch-lane-a2", 888000201, 8880002010000000001);
        _writeScratchChain("zz-scratch-lane-b2", 888000202, 8880002020000000002);
        sync.addLane("zz-scratch-lane-a2", "zz-scratch-lane-b2", CAPACITY, RATE);

        bytes32 before = keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a2"))));
        // Identical policy values: an idempotent re-run must be a byte-identical no-op.
        sync.addLane("zz-scratch-lane-a2", "zz-scratch-lane-b2", CAPACITY, RATE);
        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a2")))),
            before,
            "identical re-run mutated the file (must be byte-identical)"
        );
        _cleanAll("zz-scratch-lane-a2");
        _cleanAll("zz-scratch-lane-b2");
    }

    // An existing entry with DIFFERENT capacity/rate is NOT silently no-op'd: the WARN path (message
    // asserted in the tooling suite) still leaves the file byte-identical - the entry is never
    // rewritten in place, the operator must remove-then-add or hand-edit.
    function test_AddLane_ChangedArgsLeavesFileUnchanged() public {
        _writeScratchChain("zz-scratch-lane-a11", 888001101, 8880011010000000001);
        _writeScratchChain("zz-scratch-lane-b11", 888001102, 8880011020000000002);
        sync.addLane("zz-scratch-lane-a11", "zz-scratch-lane-b11", CAPACITY, RATE);

        bytes32 before = keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a11"))));
        // Different policy values: the entry must be left UNCHANGED (no in-place rewrite).
        sync.addLane("zz-scratch-lane-a11", "zz-scratch-lane-b11", 1, 1);
        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a11")))),
            before,
            "changed-args add-lane mutated the file (must be left unchanged)"
        );
        _cleanAll("zz-scratch-lane-a11");
        _cleanAll("zz-scratch-lane-b11");
    }

    function test_AddLane_SelfLaneRefused() public {
        _writeScratchChain("zz-scratch-lane-a3", 888000301, 8880003010000000001);
        // Same name.
        try sync.addLane("zz-scratch-lane-a3", "zz-scratch-lane-a3", CAPACITY, RATE) {
            revert("same-name self-lane not refused");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "must be different chains"), reason);
        }
        // Two files, one chainSelector (same chain under two names).
        _writeScratchChain("zz-scratch-lane-b3", 888000302, 8880003010000000001);
        try sync.addLane("zz-scratch-lane-a3", "zz-scratch-lane-b3", CAPACITY, RATE) {
            revert("shared-selector self-lane not refused");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "share chainSelector"), reason);
        }
        // Refused BEFORE any write: no project file was created for the declaring chain.
        assertFalse(vm.exists(_projPath("zz-scratch-lane-a3")), "refused lane seeded a project file");
        _cleanAll("zz-scratch-lane-a3");
        _cleanAll("zz-scratch-lane-b3");
    }

    function test_CcipSyncPreservesLanes() public {
        _writeScratchChain("zz-scratch-lane-a4", 888000401, 8880004010000000001);
        _writeScratchChain("zz-scratch-lane-b4", 888000402, 8880004020000000002);
        sync.addLane("zz-scratch-lane-a4", "zz-scratch-lane-b4", CAPACITY, RATE);
        string memory projectBefore = vm.readFile(_projPath("zz-scratch-lane-a4"));
        string memory configBefore = vm.readFile(_path("zz-scratch-lane-a4"));

        // A real `run()` through the seam, offline: the stub serves this chain's identity/metadata
        // with a DIFFERENT active router, so the sync demonstrably writes .ccip (config only).
        SyncHarness harness = new SyncHarness();
        harness.setSource(new StubConfigSource(_flatFor("zz-scratch-lane-a4", configBefore, address(0xBEEF))));
        harness.run("zz-scratch-lane-a4");

        string memory configAfter = vm.readFile(_path("zz-scratch-lane-a4"));
        assertEq(vm.parseJsonAddress(configAfter, ".ccip.router"), address(0xBEEF), "sync did not write .ccip");
        // A config sync writes only `.ccip` + the metadata keys; it must never create `lanes`/`roles`
        // in the chain file (they belong in project/). Catches a regression to a whole-file write.
        assertFalse(vm.keyExistsJson(configAfter, ".lanes"), "sync created a stray lanes{} block in config/chains");
        assertFalse(vm.keyExistsJson(configAfter, ".roles"), "sync created a stray roles{} block in config/chains");
        assertFalse(vm.keyExistsJson(configAfter, ".ccipBnM"), "sync wrote a ccipBnM field into the config");
        // The project file (lanes) is completely untouched by the config sync (byte-identical shasum).
        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a4")))),
            keccak256(bytes(projectBefore)),
            "sync mutated the project file"
        );
        assertEq(
            vm.parseJsonString(vm.readFile(_projPath("zz-scratch-lane-a4")), ".lanes.zz-scratch-lane-b4.capacity"),
            vm.toString(CAPACITY),
            "lane entry lost by sync"
        );
        // Hand-authored config keys survive too (the same targeted-merge rule).
        assertEq(vm.parseJsonString(configAfter, ".rpcEnv"), "ZZ_SCRATCH_LANE_RPC_URL", "sync mutated .rpcEnv");
        _cleanAll("zz-scratch-lane-a4");
        _cleanAll("zz-scratch-lane-b4");
    }

    /// @dev Flat source JSON (the `ccip-config-source.sh` output shape) echoing `chainJson`'s
    /// identity/metadata, with `router` overridden so the sync's write is observable.
    function _flatFor(string memory name, string memory chainJson, address router) internal returns (string memory) {
        string memory obj = string.concat("flat-", name);
        vm.serializeString(obj, "apiName", name);
        vm.serializeString(obj, "chainId", vm.parseJsonString(chainJson, ".chainId"));
        vm.serializeString(obj, "displayName", vm.parseJsonString(chainJson, ".displayName"));
        vm.serializeString(obj, "chainFamily", vm.parseJsonString(chainJson, ".chainFamily"));
        vm.serializeString(obj, "environment", vm.parseJsonString(chainJson, ".environment"));
        vm.serializeString(obj, "explorerUrl", vm.parseJsonString(chainJson, ".explorerUrl"));
        vm.serializeString(obj, "nativeCurrencySymbol", vm.parseJsonString(chainJson, ".nativeCurrencySymbol"));
        vm.serializeAddress(obj, "router", router);
        vm.serializeAddress(obj, "rmnProxy", vm.parseJsonAddress(chainJson, ".ccip.rmnProxy"));
        vm.serializeAddress(obj, "tokenAdminRegistry", vm.parseJsonAddress(chainJson, ".ccip.tokenAdminRegistry"));
        vm.serializeAddress(
            obj, "registryModuleOwnerCustom", vm.parseJsonAddress(chainJson, ".ccip.registryModuleOwnerCustom")
        );
        vm.serializeAddress(obj, "link", vm.parseJsonAddress(chainJson, ".ccip.link"));
        vm.serializeAddress(obj, "feeQuoter", vm.parseJsonAddress(chainJson, ".ccip.feeQuoter"));
        vm.serializeAddress(obj, "tokenPoolFactory", vm.parseJsonAddress(chainJson, ".ccip.tokenPoolFactory"));
        return vm.serializeAddress(obj, "feeTokens", vm.parseJsonAddressArray(chainJson, ".ccip.feeTokens"));
    }

    function test_AddLane_WithInbound_WritesInboundBlock() public {
        _writeScratchChain("zz-scratch-lane-a6", 888000601, 8880006010000000001);
        _writeScratchChain("zz-scratch-lane-b6", 888000602, 8880006020000000002);
        _writeScratchChain("zz-scratch-lane-c6", 888000603, 8880006030000000003);

        sync.addLane("zz-scratch-lane-a6", "zz-scratch-lane-b6", CAPACITY, RATE, 55, 5);
        string memory json = vm.readFile(_projPath("zz-scratch-lane-a6"));
        assertEq(vm.parseJsonString(json, ".lanes.zz-scratch-lane-b6.capacity"), vm.toString(CAPACITY), "capacity");
        assertEq(vm.parseJsonString(json, ".lanes.zz-scratch-lane-b6.rate"), vm.toString(RATE), "rate");
        assertEq(vm.parseJsonString(json, ".lanes.zz-scratch-lane-b6.inbound.capacity"), "55", "inbound capacity");
        assertEq(vm.parseJsonString(json, ".lanes.zz-scratch-lane-b6.inbound.rate"), "5", "inbound rate");

        // The 4-arg form declares NO inbound block (absent = undeclared, never defaulted).
        sync.addLane("zz-scratch-lane-a6", "zz-scratch-lane-c6", CAPACITY, RATE);
        json = vm.readFile(_projPath("zz-scratch-lane-a6"));
        assertFalse(
            vm.keyExistsJson(json, ".lanes.zz-scratch-lane-c6.inbound"),
            "4-arg add-lane must not write an inbound block"
        );
        // And the rewrite preserved the earlier lane's inbound block verbatim.
        assertEq(
            vm.parseJsonString(json, ".lanes.zz-scratch-lane-b6.inbound.capacity"),
            "55",
            "inbound block lost by a later add-lane"
        );
        _cleanAll("zz-scratch-lane-a6");
        _cleanAll("zz-scratch-lane-b6");
        _cleanAll("zz-scratch-lane-c6");
    }

    function test_AddLane_PreservesNestedBlocksOnRewrite() public {
        _writeScratchChain("zz-scratch-lane-a7", 888000701, 8880007010000000001);
        _writeScratchChain("zz-scratch-lane-b7", 888000702, 8880007020000000002);
        _writeScratchChain("zz-scratch-lane-c7", 888000703, 8880007030000000003);

        // Seed a lane entry carrying every optional block (inbound + v2 fastFinality + v2 feeConfig) via
        // the writer, then hand-inject the nested optionals onto it - as a reviewed hand edit would.
        ProjectStore._seedIfAbsent("zz-scratch-lane-a7");
        vm.writeJson(
            string.concat(
                "{\"zz-scratch-lane-b7\":{\"remoteSelector\":\"8880007020000000002\",",
                "\"capacity\":\"",
                vm.toString(CAPACITY),
                "\",\"rate\":\"",
                vm.toString(RATE),
                "\",\"inbound\":{\"capacity\":\"55\",\"rate\":\"5\"},",
                "\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"9\",\"rate\":\"2\"}},",
                "\"feeConfig\":{\"destGasOverhead\":\"90000\",\"finalityTransferFeeBps\":\"10\"}}}}"
            ),
            _projPath("zz-scratch-lane-a7"),
            ".lanes"
        );
        string memory before = vm.readFile(_projPath("zz-scratch-lane-a7"));

        // Appending another lane rewrites the .lanes subtree - the nested blocks must survive verbatim.
        sync.addLane("zz-scratch-lane-a7", "zz-scratch-lane-c7", 1, 1);
        string memory after_ = vm.readFile(_projPath("zz-scratch-lane-a7"));
        assertEq(
            _subtreeHash(before, "lanes.zz-scratch-lane-b7"),
            _subtreeHash(after_, "lanes.zz-scratch-lane-b7"),
            "add-lane mutated an existing lane's nested policy blocks"
        );
        assertEq(vm.parseJsonString(after_, ".lanes.zz-scratch-lane-c7.capacity"), "1", "new lane not written");
        assertEq(
            vm.parseJsonString(after_, ".lanes.zz-scratch-lane-b7.v2.feeConfig.destGasOverhead"),
            "90000",
            "v2.feeConfig lost by add-lane rewrite"
        );
        _cleanAll("zz-scratch-lane-a7");
        _cleanAll("zz-scratch-lane-b7");
        _cleanAll("zz-scratch-lane-c7");
    }

    // The pool-scoped poolPolicy{} block (one writer: a reviewed hand edit) must survive BOTH
    // rewriting writers verbatim: an add-lane .lanes rewrite and a full ccip sync run. A project
    // file WITHOUT the block stays byte-identical throughout (absent = undeclared, never seeded).
    function test_PoolPolicy_SurvivesAddLaneAndSync() public {
        _writeScratchChain("zz-scratch-lane-a9", 888000901, 8880009010000000001);
        _writeScratchChain("zz-scratch-lane-b9", 888000902, 8880009020000000002);
        _writeScratchChain("zz-scratch-lane-c9", 888000903, 8880009030000000003);

        // The hand-edit simulation: the whole schema-3 document with poolPolicy in sorted position.
        vm.writeFile(
            _projPath("zz-scratch-lane-a9"),
            string.concat(
                "{\"addresses\":{\"active\":{},\"deployments\":{}},\"lanes\":{},",
                "\"poolPolicy\":{\"ccvThreshold\":\"1000\",\"finality\":{\"blockDepth\":\"5\",\"waitForSafe\":true}},",
                "\"roles\":{},\"schema\":3}"
            )
        );
        string memory beforeAddLane = vm.readFile(_projPath("zz-scratch-lane-a9"));

        // An add-lane rewrites only .lanes: the sibling poolPolicy subtree survives verbatim.
        sync.addLane("zz-scratch-lane-a9", "zz-scratch-lane-b9", CAPACITY, RATE);
        string memory afterAddLane = vm.readFile(_projPath("zz-scratch-lane-a9"));
        assertEq(
            _subtreeHash(beforeAddLane, "poolPolicy"),
            _subtreeHash(afterAddLane, "poolPolicy"),
            "add-lane mutated the poolPolicy block"
        );
        assertEq(vm.parseJsonString(afterAddLane, ".poolPolicy.ccvThreshold"), "1000", "ccvThreshold lost by add-lane");
        assertEq(
            vm.parseJsonString(afterAddLane, ".lanes.zz-scratch-lane-b9.capacity"),
            vm.toString(CAPACITY),
            "lane entry not written"
        );

        // A full ccip sync run writes only config/chains: the project file stays byte-identical.
        string memory configBefore = vm.readFile(_path("zz-scratch-lane-a9"));
        SyncHarness harness = new SyncHarness();
        harness.setSource(new StubConfigSource(_flatFor("zz-scratch-lane-a9", configBefore, address(0xBEEF))));
        harness.run("zz-scratch-lane-a9");
        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a9")))),
            keccak256(bytes(afterAddLane)),
            "sync mutated a project file carrying poolPolicy"
        );
        // The sync never plants pool-scoped policy into the chain config.
        assertFalse(
            vm.keyExistsJson(vm.readFile(_path("zz-scratch-lane-a9")), ".ccvThreshold"),
            "sync wrote a ccvThreshold key into the config"
        );

        // A project file WITHOUT poolPolicy stays byte-identical through an identical-lane re-run
        // (the block is never seeded or defaulted into existence).
        sync.addLane("zz-scratch-lane-c9", "zz-scratch-lane-b9", CAPACITY, RATE);
        string memory noPolicyBefore = vm.readFile(_projPath("zz-scratch-lane-c9"));
        assertFalse(vm.keyExistsJson(noPolicyBefore, ".poolPolicy"), "no writer may create poolPolicy");
        sync.addLane("zz-scratch-lane-c9", "zz-scratch-lane-b9", CAPACITY, RATE);
        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-c9")))),
            keccak256(bytes(noPolicyBefore)),
            "identical re-run must stay byte-identical without a poolPolicy block"
        );

        _cleanAll("zz-scratch-lane-a9");
        _cleanAll("zz-scratch-lane-b9");
        _cleanAll("zz-scratch-lane-c9");
    }

    function test_MeshReciprocity_OneSidedLaneFailsFromEitherSide() public {
        _writeScratchChain("zz-scratch-lane-a5", 888000501, 8880005010000000001);
        _writeScratchChain("zz-scratch-lane-b5", 888000502, 8880005020000000002);
        sync.addLane("zz-scratch-lane-a5", "zz-scratch-lane-b5", CAPACITY, RATE);

        // Doctoring the DECLARING side: the un-reciprocated lane is a FAIL.
        (uint256 fails,) = (new VerifyChain()).checkMeshForTest("zz-scratch-lane-a5");
        assertEq(fails, 1, "one-sided lane must FAIL the declaring side's mesh rung");

        // Doctoring the OTHER side: the reverse scan catches the same one-sided lane.
        (fails,) = (new VerifyChain()).checkMeshForTest("zz-scratch-lane-b5");
        assertEq(fails, 1, "one-sided lane must FAIL the remote side's mesh rung too");

        // The reciprocal entry clears both sides.
        sync.addLane("zz-scratch-lane-b5", "zz-scratch-lane-a5", CAPACITY, RATE);
        (fails,) = (new VerifyChain()).checkMeshForTest("zz-scratch-lane-a5");
        assertEq(fails, 0, "reciprocal lane must clear the declaring side");
        (fails,) = (new VerifyChain()).checkMeshForTest("zz-scratch-lane-b5");
        assertEq(fails, 0, "reciprocal lane must clear the remote side");
        _cleanAll("zz-scratch-lane-a5");
        _cleanAll("zz-scratch-lane-b5");
    }

    // `removeLane` removes ONLY the target entry: a sibling lane carrying every nested optional
    // block (inbound{} + v2{}) survives content-identically (subtree-hash proof), and every non-lanes
    // top-level subtree of the project file is untouched.
    function test_RemoveLane_RemovesOnlyTargetEntry() public {
        _writeScratchChain("zz-scratch-lane-a8", 888000801, 8880008010000000001);
        _writeScratchChain("zz-scratch-lane-b8", 888000802, 8880008020000000002);
        _writeScratchChain("zz-scratch-lane-c8", 888000803, 8880008030000000003);

        // Sibling entry with nested inbound{} + v2{} blocks, as a reviewed hand edit would leave it.
        ProjectStore._seedIfAbsent("zz-scratch-lane-a8");
        vm.writeJson(
            string.concat(
                "{\"zz-scratch-lane-b8\":{\"remoteSelector\":\"8880008020000000002\",",
                "\"capacity\":\"",
                vm.toString(CAPACITY),
                "\",\"rate\":\"",
                vm.toString(RATE),
                "\",\"inbound\":{\"capacity\":\"55\",\"rate\":\"5\"},",
                "\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"9\",\"rate\":\"2\"}},",
                "\"feeConfig\":{\"destGasOverhead\":\"90000\",\"finalityTransferFeeBps\":\"10\"}}}}"
            ),
            _projPath("zz-scratch-lane-a8"),
            ".lanes"
        );
        sync.addLane("zz-scratch-lane-a8", "zz-scratch-lane-c8", 1, 1);
        string memory before = vm.readFile(_projPath("zz-scratch-lane-a8"));

        sync.removeLane("zz-scratch-lane-a8", "zz-scratch-lane-c8");

        string memory after_ = vm.readFile(_projPath("zz-scratch-lane-a8"));
        assertFalse(
            vm.keyExistsJson(after_, ".lanes.zz-scratch-lane-c8"), "target lane entry not removed by remove-lane"
        );
        assertEq(
            _subtreeHash(before, "lanes.zz-scratch-lane-b8"),
            _subtreeHash(after_, "lanes.zz-scratch-lane-b8"),
            "remove-lane mutated a sibling lane's nested policy blocks"
        );
        // Every top-level subtree except `lanes` is content-identical (subtree isolation).
        string[] memory keys = vm.parseJsonKeys(before, ".");
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes("lanes"))) continue;
            assertEq(
                _subtreeHash(before, keys[i]),
                _subtreeHash(after_, keys[i]),
                string.concat("remove-lane mutated project .", keys[i])
            );
        }
        _cleanAll("zz-scratch-lane-a8");
        _cleanAll("zz-scratch-lane-b8");
        _cleanAll("zz-scratch-lane-c8");
    }

    // Removing a lane that is NOT declared is a logged no-op leaving the file byte-identical
    // (the same idempotence contract a duplicate add-lane has).
    function test_RemoveLane_UndeclaredIsByteIdenticalNoOp() public {
        _writeScratchChain("zz-scratch-lane-a9", 888000901, 8880009010000000001);
        _writeScratchChain("zz-scratch-lane-b9", 888000902, 8880009020000000002);
        sync.addLane("zz-scratch-lane-a9", "zz-scratch-lane-b9", CAPACITY, RATE);
        bytes32 before = keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a9"))));

        sync.removeLane("zz-scratch-lane-a9", "zz-scratch-lane-never-declared");

        assertEq(
            keccak256(bytes(vm.readFile(_projPath("zz-scratch-lane-a9")))),
            before,
            "undeclared remove-lane mutated the file (must be a byte-identical no-op)"
        );
        _cleanAll("zz-scratch-lane-a9");
        _cleanAll("zz-scratch-lane-b9");
    }

    // A missing config file is a named refusal (the helpful known-chains list), never a raw
    // cheatcode revert.
    function test_RemoveLane_MissingConfigRefusedByName() public {
        try sync.removeLane("zz-scratch-lane-does-not-exist", "zz-scratch-lane-b9") {
            revert("missing config not refused");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "zz-scratch-lane-does-not-exist"), reason);
            assertTrue(_contains(reason, "Known chains:"), reason);
        }
    }

    // Remove-then-readd round-trip: after removeLane + addLane with the same values, the lanes
    // subtree is content-equal to the original. Compared via the parsed-value subtree hash (the
    // same content notion every isolation test uses), not raw bytes: key order is not part of
    // the contract.
    function test_RemoveLane_ThenReAdd_RoundTripsLanesSubtree() public {
        _writeScratchChain("zz-scratch-lane-a10", 888001001, 8880010010000000001);
        _writeScratchChain("zz-scratch-lane-b10", 888001002, 8880010020000000002);
        sync.addLane("zz-scratch-lane-a10", "zz-scratch-lane-b10", CAPACITY, RATE, 55, 5);
        string memory before = vm.readFile(_projPath("zz-scratch-lane-a10"));

        sync.removeLane("zz-scratch-lane-a10", "zz-scratch-lane-b10");
        assertFalse(
            vm.keyExistsJson(vm.readFile(_projPath("zz-scratch-lane-a10")), ".lanes.zz-scratch-lane-b10"),
            "lane not removed before the re-add"
        );
        sync.addLane("zz-scratch-lane-a10", "zz-scratch-lane-b10", CAPACITY, RATE, 55, 5);

        string memory after_ = vm.readFile(_projPath("zz-scratch-lane-a10"));
        assertEq(
            _subtreeHash(before, "lanes"),
            _subtreeHash(after_, "lanes"),
            "remove-then-readd did not round-trip the lanes subtree"
        );
        _cleanAll("zz-scratch-lane-a10");
        _cleanAll("zz-scratch-lane-b10");
    }
}
