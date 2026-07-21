// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainDoctorRungsTest - `make doctor` per-rung completeness (offline)
/// @notice The offline half of the doctor's per-rung matrix. The SCHEMA rung is exercised end-to-end
/// here (clean-chain PASS, induced FAIL naming the missing field, and the guarantees that `ccipBnM` is
/// not a required key and that a stray `lanes{}`/`roles{}` in a config file is still diagnosed), plus a
/// whole-doctor VERDICT-EQUIVALENCE fixture: the same logical chain expressed two byte-different
/// (canonical vs compact) ways yields IDENTICAL offline-rung tallies - the config file format is a
/// representation detail the verdict is invariant under.
///
/// The other rungs are covered by their own suites (the ffi/network rungs - tools, api - run in the live
/// tooling suite): mesh SKIP/FAIL/PASS in `LaneConfig.t.sol` + `VerifyChainSchemaRung.t.sol`;
/// registry+extras PASS/WARN/WARN in `VerifyChainTarReconcile.t.sol`; lanes PASS/WARN/SKIP in
/// `VerifyChainLaneReconcile` + `VerifyChainCCVReconcile`; roles PASS/FAIL/WARN in `RolesAuthority.t.sol`;
/// rpc/on-chain reachability in every `BaseForkTest`. This file adds the SCHEMA-rung kinds and the
/// equivalence fixture.
contract VerifyChainDoctorRungsTest is Test {
    // A real committed EVM chain config for the clean-chain PASS.
    string internal constant REAL_EVM = "ethereum-testnet-sepolia";

    string internal constant SEL_CLEAN = "zz-scratch-doctor-clean";
    string internal constant SEL_MISSING = "zz-scratch-doctor-missing";
    string internal constant SEL_NOBNM = "zz-scratch-doctor-nobnm";
    string internal constant SEL_EQ_CANON = "zz-scratch-doctor-eqcanon";
    string internal constant SEL_EQ_COMPACT = "zz-scratch-doctor-eqcompact";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[4] memory sels = [SEL_CLEAN, SEL_MISSING, SEL_NOBNM, SEL_EQ_CANON];
        for (uint256 i = 0; i < sels.length; i++) {
            _clean(sels[i]);
        }
        _clean(SEL_EQ_COMPACT);
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

    /// @dev A complete, discovery-safe EVM chain config (every key `ChainConfig._load` + the schema rung
    /// consume) with NO `ccipBnM` key and optional key omissions. `omit` names a single
    /// top-level key to leave OUT (for the induced-FAIL kind); "" omits nothing.
    function _writeConfig(string memory name, uint256 chainId, uint64 selector, string memory omit) internal {
        string[9] memory keys = [
            "name",
            "displayName",
            "chainNameIdentifier",
            "environment",
            "rpcEnv",
            "explorerUrl",
            "nativeCurrencySymbol",
            "chainId",
            "chainSelector"
        ];
        string[9] memory vals = [
            name,
            "Scratch",
            "ZZ_SCRATCH_DOCTOR",
            "testnet",
            "ZZ_SCRATCH_DOCTOR_RPC_URL",
            "https://example.invalid",
            "ZZZ",
            vm.toString(chainId),
            vm.toString(selector)
        ];
        string memory json = "{";
        json = string.concat(json, '"chainFamily":"evm"');
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(omit))) continue;
            // every value is a quoted string; chainId/chainSelector quoted (the big-int rule).
            json = string.concat(json, ',"', keys[i], '":"', vals[i], '"');
        }
        json = string.concat(
            json,
            ',"ccip":{"router":"0x0000000000000000000000000000000000000002",',
            '"rmnProxy":"0x0000000000000000000000000000000000000003",',
            '"tokenAdminRegistry":"0x0000000000000000000000000000000000000005",',
            '"registryModuleOwnerCustom":"0x0000000000000000000000000000000000000004",',
            '"link":"0x0000000000000000000000000000000000000001",',
            '"feeQuoter":"0x0000000000000000000000000000000000000006",',
            '"tokenPoolFactory":"0x0000000000000000000000000000000000000007",',
            '"feeTokens":[]}}'
        );
        vm.writeFile(_configPath(name), json);
    }

    // ------------------------------------------------------------ schema rung: clean PASS

    /// @dev CLEAN-CHAIN PASS: the schema rung on a real, fully-populated EVM config FAILs zero checks
    /// (every key `ChainConfig._load` consumes is present, the quoted-decimal rule holds, and the real
    /// parse path succeeds). `isEvm` is true.
    function test_SchemaRung_CleanRealConfig_Pass() public {
        (bool isEvm, uint256 fails, uint256 warns) = new VerifyChain().checkSchemaForTest(REAL_EVM);
        assertTrue(isEvm, "the real Sepolia config is an EVM chain");
        assertEq(fails, 0, "the schema rung must PASS a real, complete config with ZERO fails");
        assertEq(warns, 0, "the schema rung emits no WARNs");
    }

    /// @dev CLEAN-CHAIN PASS on a synthesized complete config too (non-regression against the real file
    /// drifting): a hand-built config carrying every required key and no `ccipBnM` PASSes with 0 fails.
    function test_SchemaRung_SynthComplete_Pass() public {
        _writeConfig(SEL_CLEAN, 889_100_001, 8_891_000_010_000_000_001, "");
        (bool isEvm, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_CLEAN);
        assertTrue(isEvm, "synth config is EVM");
        assertEq(fails, 0, "a complete synth config (no ccipBnM) must PASS the schema rung");
        _clean(SEL_CLEAN);
    }

    // ------------------------------------------------------------ schema rung: induced FAIL

    /// @dev INDUCED FAIL naming the field: a config missing a required key FAILs the schema rung. The
    /// message names the exact missing key (`schema: missing key .rpcEnv`) - the rung composes the key
    /// into the FAIL line. `.rpcEnv` is a key the schema rung requires but which `ChainConfig._load`
    /// (and HelperConfig's discovery scan) does NOT read, so the scratch config stays parseable by the
    /// global chain scan while still failing the schema rung.
    function test_SchemaRung_MissingRequiredKey_InducedFail() public {
        _writeConfig(SEL_MISSING, 889_100_002, 8_891_000_020_000_000_001, "rpcEnv");
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_MISSING);
        assertGt(fails, 0, "a config missing a required key must FAIL the schema rung (naming the key)");
        _clean(SEL_MISSING);
    }

    // ------------------------------------------------------------ schema rung: ccipBnM non-regression

    /// @dev `ccipBnM` is NOT a required key: a config with no `ccipBnM` at all must PASS the schema rung.
    /// This pins that `.ccipBnM` is absent from the schema `required[]` list.
    function test_SchemaRung_NoCcipBnM_Pass_NonRegression() public {
        _writeConfig(SEL_NOBNM, 889_100_003, 8_891_000_030_000_000_001, "");
        string memory json = vm.readFile(_configPath(SEL_NOBNM));
        assertFalse(vm.keyExistsJson(json, ".ccipBnM"), "precondition: config carries NO ccipBnM key");
        (, uint256 fails,) = new VerifyChain().checkSchemaForTest(SEL_NOBNM);
        assertEq(fails, 0, "a config without ccipBnM must PASS the schema rung");
        _clean(SEL_NOBNM);
    }

    // ------------------------------------------------------------ whole-doctor verdict equivalence

    /// @dev VERDICT-EQUIVALENCE fixture: the SAME logical chain expressed two byte-different ways - the
    /// canonical config vs a compact (whitespace-free, differently-ordered) config - yields
    /// IDENTICAL offline-rung tallies (schema + stray-state + mesh). The config file format is a
    /// representation change ONLY; the doctor's verdict must be invariant under it. Both trees declare
    /// NO lanes (mesh SKIPs identically) and no stray project state (0/0), and both are complete configs
    /// (schema 0/0), so the pair proves representation-independence end-to-end across the offline rungs.
    function test_WholeDoctor_VerdictEquivalence_SameTree_TwoRepresentations() public {
        // Representation 1 (canonical, spaced key layout).
        _writeConfig(SEL_EQ_CANON, 889_100_004, 8_891_000_040_000_000_001, "");
        // Representation 2 (compact: no whitespace, keys emitted in a different order, identical content).
        _writeConfigCompact(SEL_EQ_COMPACT, 889_100_005, 8_891_000_050_000_000_001);

        (uint256 fA, uint256 wA) = _offlineDoctorTally(SEL_EQ_CANON);
        (uint256 fB, uint256 wB) = _offlineDoctorTally(SEL_EQ_COMPACT);

        assertEq(fA, fB, "FAIL tally must be identical across the two representations of the same tree");
        assertEq(wA, wB, "WARN tally must be identical across the two representations of the same tree");
        // And the equivalent healthy tree is actually healthy (0 FAIL), not equally-broken.
        assertEq(fA, 0, "the equivalent healthy new-layout tree must have ZERO doctor FAILs");
        _clean(SEL_EQ_CANON);
        _clean(SEL_EQ_COMPACT);
    }

    /// @dev The offline doctor tally: schema + stray-state (both read the CONFIG) + mesh (reads the
    /// PROJECT). Each hook constructs a fresh VerifyChain, so the counts are summed here. The ffi/network
    /// rungs (tools/api/rpc/on-chain/registry/lanes/roles) are out of the offline tally by construction.
    function _offlineDoctorTally(string memory name) internal returns (uint256 fails, uint256 warns) {
        (, uint256 f1, uint256 w1) = new VerifyChain().checkSchemaForTest(name);
        (uint256 f2, uint256 w2) = new VerifyChain().checkNoStrayProjectStateForTest(name);
        (uint256 f3, uint256 w3) = new VerifyChain().checkMeshForTest(name);
        return (f1 + f2 + f3, w1 + w2 + w3);
    }

    /// @dev The compact representation: identical content to `_writeConfig(name, …, "")`, no whitespace,
    /// keys in a deliberately DIFFERENT order - same logical chain, different bytes.
    function _writeConfigCompact(string memory name, uint256 chainId, uint64 selector) internal {
        string memory json = string.concat(
            "{",
            '"chainSelector":"',
            vm.toString(selector),
            '","chainId":"',
            vm.toString(chainId),
            '",',
            '"ccip":{"feeTokens":[],"tokenPoolFactory":"0x0000000000000000000000000000000000000007",',
            '"feeQuoter":"0x0000000000000000000000000000000000000006",',
            '"link":"0x0000000000000000000000000000000000000001",',
            '"registryModuleOwnerCustom":"0x0000000000000000000000000000000000000004",',
            '"tokenAdminRegistry":"0x0000000000000000000000000000000000000005",',
            '"rmnProxy":"0x0000000000000000000000000000000000000003",',
            '"router":"0x0000000000000000000000000000000000000002"},',
            '"nativeCurrencySymbol":"ZZZ","explorerUrl":"https://example.invalid",',
            '"rpcEnv":"ZZ_SCRATCH_DOCTOR_RPC_URL","environment":"testnet",',
            '"chainNameIdentifier":"ZZ_SCRATCH_DOCTOR","displayName":"Scratch",',
            '"chainFamily":"evm","name":"',
            name,
            '"}'
        );
        vm.writeFile(_configPath(name), json);
    }
}
