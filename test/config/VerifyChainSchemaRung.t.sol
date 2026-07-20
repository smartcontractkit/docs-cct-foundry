// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainSchemaRungTest - doctor schema rung (stray-state diagnostic +
/// no-project SKIP)
/// @notice Two doctor behaviors, offline (no fork):
///   1. **Stale-chain diagnostic** - a `config/chains/<name>.json` still carrying a `lanes{}` or
///      `roles{}` block, or a `ccvThreshold` key (pool-scoped policy: `poolPolicy.ccvThreshold` in
///      the project store), gets a NAMED FAIL that points at `project/<name>.json`,
///      a clear diagnostic, never a cryptic one. A pure API/chain-facts config neither FAILs nor WARNs
///      (non-regression).
///   2. **No-project SKIP** - the mesh (lanes) rung on a chain that has a config but NO project file
///      cleanly SKIPs (0 FAIL / 0 WARN): an absent project store is a normal "no lanes
///      declared" state, and the reader returns the `"{}"` sentinel so `keyExistsJson` never raw-reverts.
///   3. **verifier{} validation + confirmations removal**: the optional `verifier{type,url}` block
///      passes when valid (etherscan/blockscout/sourcify; blockscout with an http(s) url) and FAILs by
///      name when malformed (unknown type; a structurally-wrong array/object type; blockscout with a
///      missing, empty, or non-http url) without ever raw-reverting the doctor; a stray `confirmations`
///      key (the removed field) is a NAMED FAIL; a config without either is clean (non-regression).
/// Every test writes uniquely-named `config/chains/zz-scratch-*` (discovery-safe, all chain-fact keys)
/// and cleans both config + project in setUp() (revert-safe, gitignored).
contract VerifyChainSchemaRungTest is Test {
    string internal constant SEL_CLEAN = "zz-scratch-schema-clean";
    string internal constant SEL_STRAY_LANES = "zz-scratch-schema-straylanes";
    string internal constant SEL_STRAY_ROLES = "zz-scratch-schema-strayroles";
    string internal constant SEL_STRAY_THRESHOLD = "zz-scratch-schema-straythreshold";
    string internal constant SEL_NOPROJECT = "zz-scratch-schema-noproject";
    string internal constant SEL_STRAY_CONF = "zz-scratch-schema-strayconf";
    string internal constant SEL_VER_BS = "zz-scratch-schema-verblockscout";
    string internal constant SEL_VER_SRC = "zz-scratch-schema-versourcify";
    string internal constant SEL_VER_BAD = "zz-scratch-schema-verbadtype";
    string internal constant SEL_VER_NOURL = "zz-scratch-schema-vernourl";
    string internal constant SEL_VER_EMPTYURL = "zz-scratch-schema-veremptyurl";
    string internal constant SEL_VER_ARRTYPE = "zz-scratch-schema-verarrtype";
    string internal constant SEL_VER_NUMURL = "zz-scratch-schema-vernumurl";
    string internal constant SEL_VER_ARRURL = "zz-scratch-schema-verarrurl";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[13] memory sels = [
            SEL_CLEAN,
            SEL_STRAY_LANES,
            SEL_STRAY_ROLES,
            SEL_NOPROJECT,
            SEL_STRAY_CONF,
            SEL_VER_BS,
            SEL_VER_SRC,
            SEL_VER_BAD,
            SEL_VER_NOURL,
            SEL_VER_EMPTYURL,
            SEL_VER_ARRTYPE,
            SEL_VER_NUMURL,
            SEL_VER_ARRURL
        ];
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
        string memory p = ProjectStore._path(name);
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
    // SKIPs (0/0). An absent project store is a normal "no lanes declared" state - the reader
    // returns "{}" so keyExistsJson never raw-reverts (an empty/absent project store is not an error).
    function test_MeshRung_NoProjectFile_SkipsCleanly() public {
        _writeConfig(SEL_NOPROJECT, 889000401, 8890004010000000001, "");
        assertFalse(vm.exists(ProjectStore._path(SEL_NOPROJECT)), "precondition: no project file for this chain");
        (uint256 fails, uint256 warns) = new VerifyChain().checkMeshForTest(SEL_NOPROJECT);
        assertEq(fails, 0, "a chain with no project file must not FAIL the mesh rung (absent = no lanes)");
        assertEq(warns, 0, "a chain with no project file must not WARN the mesh rung");
        _clean(SEL_NOPROJECT);
    }

    // (5) A stray `confirmations` key (the removed field) is a NAMED schema FAIL. The clean config in
    // (1) has no such key and 0 fails, pinning the removal as the valid state.
    function test_SchemaRung_StrayConfirmations_NamedFail() public {
        _writeConfig(SEL_STRAY_CONF, 889000501, 8890005010000000001, ',"confirmations":2');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_STRAY_CONF);
        assertEq(fails, 1, "a config still carrying the removed confirmations key must FAIL exactly once");
        _clean(SEL_STRAY_CONF);
    }

    // (6) A valid blockscout verifier{} (type + url) passes the schema rung with 0 fails.
    function test_SchemaRung_VerifierBlockscoutWithUrl_Pass() public {
        _writeConfig(
            SEL_VER_BS,
            889000601,
            8890006010000000001,
            ',"verifier":{"type":"blockscout","url":"https://x.invalid/api"}'
        );
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_BS);
        assertEq(fails, 0, "a valid blockscout verifier{} must not FAIL the schema rung");
        _clean(SEL_VER_BS);
    }

    // (7) A sourcify verifier{} needs no url (keyless, fixed endpoint) and passes.
    function test_SchemaRung_VerifierSourcify_Pass() public {
        _writeConfig(SEL_VER_SRC, 889000701, 8890007010000000001, ',"verifier":{"type":"sourcify"}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_SRC);
        assertEq(fails, 0, "a sourcify verifier{} (no url) must not FAIL the schema rung");
        _clean(SEL_VER_SRC);
    }

    // (8) An unknown verifier.type is a NAMED FAIL (etherscan/blockscout/sourcify are the catalog).
    function test_SchemaRung_VerifierUnknownType_NamedFail() public {
        _writeConfig(SEL_VER_BAD, 889000801, 8890008010000000001, ',"verifier":{"type":"blockchair"}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_BAD);
        assertEq(fails, 1, "an unknown verifier.type must FAIL the schema rung exactly once");
        _clean(SEL_VER_BAD);
    }

    // (9) blockscout without a url is a NAMED FAIL: its instance API endpoint cannot be derived.
    function test_SchemaRung_VerifierBlockscoutNoUrl_NamedFail() public {
        _writeConfig(SEL_VER_NOURL, 889000901, 8890009010000000001, ',"verifier":{"type":"blockscout"}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_NOURL);
        assertEq(fails, 1, "verifier.type blockscout without a verifier.url must FAIL exactly once");
        _clean(SEL_VER_NOURL);
    }

    // (10) blockscout with an EMPTY url is the same NAMED FAIL: the doctor and the flag composer must
    // agree, and verify-args.sh rejects an empty url (jq's // empty), so the doctor cannot pass it.
    function test_SchemaRung_VerifierBlockscoutEmptyUrl_NamedFail() public {
        _writeConfig(SEL_VER_EMPTYURL, 889001001, 8890010010000000001, ',"verifier":{"type":"blockscout","url":""}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_EMPTYURL);
        assertEq(fails, 1, "verifier.type blockscout with an empty verifier.url must FAIL exactly once");
        _clean(SEL_VER_EMPTYURL);
    }

    // (11) A structurally-wrong verifier.type (a JSON array, not a string) is a NAMED FAIL, never a
    // raw cheatcode revert that aborts the doctor: the parse is routed through the probe and caught.
    function test_SchemaRung_VerifierArrayType_NamedFail() public {
        _writeConfig(SEL_VER_ARRTYPE, 889001101, 8890011010000000001, ',"verifier":{"type":["blockscout"]}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_ARRTYPE);
        assertEq(fails, 1, "a verifier.type written as a JSON array must FAIL by name (not revert) exactly once");
        _clean(SEL_VER_ARRTYPE);
    }

    // (12) A blockscout verifier.url written as a bare number is a NAMED FAIL: parseJsonString would
    // coerce 123 to "123", so the rung shape-checks the url for an http(s) prefix and rejects it.
    function test_SchemaRung_VerifierNumericUrl_NamedFail() public {
        _writeConfig(SEL_VER_NUMURL, 889001201, 8890012010000000001, ',"verifier":{"type":"blockscout","url":123}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_NUMURL);
        assertEq(fails, 1, "a blockscout verifier.url that is not an http(s) string must FAIL exactly once");
        _clean(SEL_VER_NUMURL);
    }

    // (13) A blockscout verifier.url written as a JSON array is a NAMED FAIL, not a raw revert: the
    // probe-routed parse makes the array-not-a-string revert catchable so the doctor names the fix.
    function test_SchemaRung_VerifierArrayUrl_NamedFail() public {
        _writeConfig(SEL_VER_ARRURL, 889001301, 8890013010000000001, ',"verifier":{"type":"blockscout","url":["x"]}');
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_VER_ARRURL);
        assertEq(fails, 1, "a blockscout verifier.url written as a JSON array must FAIL by name (not revert) once");
        _clean(SEL_VER_ARRURL);
    }
}
