// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainSchemaRungTest — doctor schema rung (stray-state diagnostic +
/// no-project SKIP)
/// @notice Two doctor behaviors, offline (no fork):
///   1. **Stale-chain diagnostic** — a `config/chains/<name>.json` still carrying a `lanes{}` or
///      `roles{}` block, or a `ccvThreshold` key (pool-scoped policy: `poolPolicy.ccvThreshold` in
///      the project store), gets a NAMED FAIL that points at `project/<name>.json`,
///      a clear diagnostic, never a cryptic one. A pure API/chain-facts config neither FAILs nor WARNs
///      (non-regression).
///   2. **No-project SKIP** — the mesh (lanes) rung on a chain that has a config but NO project file
///      cleanly SKIPs (0 FAIL / 0 WARN): an absent project store is a normal "no lanes
///      declared" state, and the reader returns the `"{}"` sentinel so `keyExistsJson` never raw-reverts.
/// Every test writes uniquely-named `config/chains/zz-scratch-*` (discovery-safe, all chain-fact keys)
/// and cleans both config + project in setUp() (revert-safe, gitignored).
contract VerifyChainSchemaRungTest is Test {
    string internal constant SEL_CLEAN = "zz-scratch-schema-clean";
    string internal constant SEL_STRAY_LANES = "zz-scratch-schema-straylanes";
    string internal constant SEL_STRAY_ROLES = "zz-scratch-schema-strayroles";
    string internal constant SEL_STRAY_THRESHOLD = "zz-scratch-schema-straythreshold";
    string internal constant SEL_NOPROJECT = "zz-scratch-schema-noproject";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[5] memory sels = [SEL_CLEAN, SEL_STRAY_LANES, SEL_STRAY_ROLES, SEL_STRAY_THRESHOLD, SEL_NOPROJECT];
        for (uint256 i = 0; i < sels.length; i++) {
            _clean(sels[i]);
        }
    }

    function _configPath(string memory name) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/config/chains/", name, ".json");
    }

    function _clean(string memory name) internal {
        string memory c = _configPath(name);
        if (vm.exists(c)) vm.removeFile(c);
        string memory p = ProjectStore.path(name);
        if (vm.exists(p)) vm.removeFile(p);
    }

    /// @dev Writes a discovery-safe scratch chain config (all API/chain-fact keys), optionally appending
    /// a raw `strayBlock` (e.g. `,"lanes":{...}`) INSIDE the top-level object to simulate a stale
    /// stale file. `strayBlock` is inserted right before the closing brace.
    function _writeConfig(string memory name, uint256 chainId, uint64 selector, string memory strayBlock) internal {
        string memory base = string.concat(
            "{",
            '"name":"',
            name,
            '",',
            '"displayName":"Scratch",',
            '"chainNameIdentifier":"ZZ_SCRATCH_SCHEMA",',
            '"chainFamily":"evm",',
            '"environment":"testnet",',
            '"chainId":"',
            vm.toString(chainId),
            '",',
            '"chainSelector":"',
            vm.toString(selector),
            '",',
            '"rpcEnv":"ZZ_SCRATCH_SCHEMA_RPC_URL",',
            '"confirmations":2,',
            '"explorerUrl":"https://example.invalid",',
            '"nativeCurrencySymbol":"ZZZ",',
            '"ccip":{"router":"0x0000000000000000000000000000000000000002",',
            '"rmnProxy":"0x0000000000000000000000000000000000000003",',
            '"tokenAdminRegistry":"0x0000000000000000000000000000000000000005",',
            '"registryModuleOwnerCustom":"0x0000000000000000000000000000000000000004",',
            '"link":"0x0000000000000000000000000000000000000001",',
            '"feeQuoter":"0x0000000000000000000000000000000000000006",',
            '"tokenPoolFactory":"0x0000000000000000000000000000000000000007",',
            '"feeTokens":[]}',
            strayBlock,
            "}"
        );
        vm.writeFile(_configPath(name), base);
    }

    // (1) Clean config (pure API/chain facts): the stray-state diagnostic neither FAILs nor WARNs.
    function test_StrayState_CleanConfig_NoFailNoWarn() public {
        _writeConfig(SEL_CLEAN, 889000101, 8890001010000000001, "");
        (uint256 fails, uint256 warns) = new VerifyChain().checkNoStrayProjectStateForTest(SEL_CLEAN);
        assertEq(fails, 0, "a pure API config must not FAIL the stray-state diagnostic");
        assertEq(warns, 0, "a pure API config must not WARN the stray-state diagnostic");
        _clean(SEL_CLEAN);
    }

    // (2) Stale config still carrying lanes{}: a NAMED FAIL pointing at project/<name>.json.
    function test_StrayState_ConfigWithLanes_NamedFail() public {
        _writeConfig(
            SEL_STRAY_LANES,
            889000201,
            8890002010000000001,
            ',"lanes":{"some-remote":{"remoteSelector":"1","capacity":"1","rate":"1"}}'
        );
        (uint256 fails,) = new VerifyChain().checkNoStrayProjectStateForTest(SEL_STRAY_LANES);
        assertEq(fails, 1, "a config still carrying lanes{} must FAIL the stray-state diagnostic exactly once");
        _clean(SEL_STRAY_LANES);
    }

    // (3) Stale config still carrying roles{}: a NAMED FAIL pointing at project/<name>.json.
    function test_StrayState_ConfigWithRoles_NamedFail() public {
        _writeConfig(SEL_STRAY_ROLES, 889000301, 8890003010000000001, ',"roles":{"token":{"type":"crosschain"}}');
        (uint256 fails,) = new VerifyChain().checkNoStrayProjectStateForTest(SEL_STRAY_ROLES);
        assertEq(fails, 1, "a config still carrying roles{} must FAIL the stray-state diagnostic exactly once");
        _clean(SEL_STRAY_ROLES);
    }

    // (4) Stale config carrying a ccvThreshold: a NAMED FAIL pointing at poolPolicy.ccvThreshold in
    // project/<name>.json (pool-scoped policy never lives in the API-synced config file).
    function test_StrayState_ConfigWithCcvThreshold_NamedFail() public {
        _writeConfig(SEL_STRAY_THRESHOLD, 889000501, 8890005010000000001, ',"ccvThreshold":"1000"');
        (uint256 fails,) = new VerifyChain().checkNoStrayProjectStateForTest(SEL_STRAY_THRESHOLD);
        assertEq(fails, 1, "a config carrying ccvThreshold must FAIL the stray-state diagnostic exactly once");
        _clean(SEL_STRAY_THRESHOLD);
    }

    // (5) No-project SKIP: the mesh (lanes) rung on a chain that has a config but NO project file cleanly
    // SKIPs (0/0). An absent project store is a normal "no lanes declared" state — the reader
    // returns "{}" so keyExistsJson never raw-reverts (an empty/absent project store is not an error).
    function test_MeshRung_NoProjectFile_SkipsCleanly() public {
        _writeConfig(SEL_NOPROJECT, 889000401, 8890004010000000001, "");
        assertFalse(vm.exists(ProjectStore.path(SEL_NOPROJECT)), "precondition: no project file for this chain");
        (uint256 fails, uint256 warns) = new VerifyChain().checkMeshForTest(SEL_NOPROJECT);
        assertEq(fails, 0, "a chain with no project file must not FAIL the mesh rung (absent = no lanes)");
        assertEq(warns, 0, "a chain with no project file must not WARN the mesh rung");
        _clean(SEL_NOPROJECT);
    }
}
