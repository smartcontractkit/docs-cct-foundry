// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {SetFinalityConfig} from "../../script/configure/finality-config/SetFinalityConfig.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev Exposes SetFinalityConfig's finality-config input ladder with the env access swapped for an
///      injectable fake (the `_env*` seams exist for exactly this — env vars are process-global and
///      forge runs suites in parallel, so tests must never vm.setEnv shared names). The resolution
///      reads the local chain config + project store from files, so each test pins block.chainid to
///      a uniquely-named scratch chain it writes.
contract FinalityLadderHarness is SetFinalityConfig {
    mapping(bytes32 => string) private fakeEnv;

    function setFakeEnv(string memory name, string memory value) external {
        fakeEnv[keccak256(bytes(name))] = value;
    }

    function _envExists(string memory name) internal view override returns (bool) {
        return bytes(fakeEnv[keccak256(bytes(name))]).length != 0;
    }

    function _envBool(string memory name, bool defaultValue) internal view override returns (bool) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? defaultValue : vm.parseBool(value);
    }

    function _envUint(string memory name) internal view override returns (uint256) {
        string memory value = fakeEnv[keccak256(bytes(name))];
        return bytes(value).length == 0 ? 0 : vm.parseUint(value);
    }

    function resolveFinality() external view returns (FinalityResolution memory) {
        return _resolveFinality();
    }
}

/// @notice SetFinalityConfig's finality-config input ladder: env (either variable present, even
///         explicitly false) > declared `poolPolicy.finality` in the project store (an empty block
///         declares the WAIT_FOR_FINALITY default) > the WAIT_FOR_FINALITY reset. An env value that
///         a declaration does not match prints the divergence notice and closing hand-edit hint
///         (byte-exact, both sides raw + decoded); an env apply with no declaration hints; the
///         declared-absent case is bit-identical to the historical env-only behavior. Each test
///         writes its own uniquely-named scratch chain and pins block.chainid to it.
contract SetFinalityConfigLadderTest is LaneReconcileScratch {
    FinalityLadderHarness internal harness;

    function setUp() public {
        _clean();
        harness = new FinalityLadderHarness();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[8] memory names = [
            "zz-scratch-ladder-env-diverges",
            "zz-scratch-ladder-env-false-wins",
            "zz-scratch-ladder-env-agrees",
            "zz-scratch-ladder-env-undeclared",
            "zz-scratch-ladder-declared-only",
            "zz-scratch-ladder-declared-empty",
            "zz-scratch-ladder-neither-reset",
            "zz-scratch-ladder-over-range"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            _cleanupScratchOne(names[i]);
        }
    }

    function _localChain(uint256 n, string memory name) internal returns (string memory) {
        uint256 chainId = 887_602_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_876_020_000_000_000_000 + n * 100 + 1));
        vm.chainId(chainId);
        return name;
    }

    /// Rung 1: an env value wins over a diverging declaration; the notice and hint fire byte-exact.
    function test_Rung1_EnvDivergesFromDeclared_NoticeAndHint() public {
        string memory local = _localChain(1, "zz-scratch-ladder-env-diverges");
        _declarePoolPolicy(local, "{\"finality\":{\"waitForSafe\":true}}");
        harness.setFakeEnv("BLOCK_DEPTH", "5");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertTrue(res.fromEnv, "env rung must win");
        assertFalse(res.fromDeclared, "env-resolved value is not fromDeclared");
        assertEq(res.value, bytes4(uint32(5)), "env block depth applied");
        assertTrue(res.diverges, "env value must diverge from the declaration");
        assertEq(
            res.notice,
            string.concat(
                unicode"⚠️  Finality env override 0x00000005 (BLOCK_DEPTH (5 blocks)) diverges from declared poolPolicy.finality 0x00010000 (WAIT_FOR_SAFE) in project/",
                local,
                ".json - make doctor will FAIL until reconciled"
            ),
            "composed finality divergence notice"
        );
        assertEq(
            res.hint,
            string.concat(
                unicode"⚠️  Applied finality config 0x00000005 is diverging from poolPolicy.finality (project/",
                local,
                ".json). Hand-edit the block to blockDepth=5 waitForSafe=false - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed finality edit hint"
        );

        _cleanupScratchOne(local);
    }

    /// Rung 1: an EXPLICIT false env value still pins the env rung (env-present-wins), so a truthy
    /// declaration diverges from the applied WAIT_FOR_FINALITY reset.
    function test_Rung1_ExplicitFalseEnvStillWins() public {
        string memory local = _localChain(2, "zz-scratch-ladder-env-false-wins");
        _declarePoolPolicy(local, "{\"finality\":{\"waitForSafe\":true}}");
        harness.setFakeEnv("WAIT_FOR_SAFE", "false");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertTrue(res.fromEnv, "an explicitly false env var still pins the env rung");
        assertEq(res.value, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "explicit false resolves the default");
        assertTrue(res.diverges, "the truthy declaration diverges from the applied default");

        _cleanupScratchOne(local);
    }

    /// Rung 1: an env value that AGREES with the declaration applies silently (no notice, no hint).
    function test_Rung1_EnvAgreesWithDeclared_Silent() public {
        string memory local = _localChain(3, "zz-scratch-ladder-env-agrees");
        _declarePoolPolicy(local, "{\"finality\":{\"blockDepth\":\"32\",\"waitForSafe\":true}}");
        harness.setFakeEnv("BLOCK_DEPTH", "32");
        harness.setFakeEnv("WAIT_FOR_SAFE", "true");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertTrue(res.fromEnv, "env rung wins");
        assertEq(res.value, FinalityCodec.WAIT_FOR_SAFE_FLAG | bytes4(uint32(32)), "combined modes encoded");
        assertFalse(res.diverges, "an agreeing env value does not diverge");
        assertEq(bytes(res.notice).length, 0, "no notice");
        assertEq(bytes(res.hint).length, 0, "no hint");

        _cleanupScratchOne(local);
    }

    /// Rung 1 with no declaration: the env value applies and the not-declared hint fires.
    function test_Rung1_EnvUndeclared_NotDeclaredHint() public {
        string memory local = _localChain(4, "zz-scratch-ladder-env-undeclared");
        harness.setFakeEnv("WAIT_FOR_SAFE", "true");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertTrue(res.fromEnv, "env rung wins");
        assertFalse(res.declared, "nothing declared");
        assertFalse(res.diverges, "nothing to diverge from");
        assertEq(
            res.hint,
            string.concat(
                unicode"⚠️  Applied finality config 0x00010000 is not declared as poolPolicy.finality (project/",
                local,
                ".json). Hand-edit the block to blockDepth=0 waitForSafe=true - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed not-declared edit hint"
        );

        _cleanupScratchOne(local);
    }

    /// Rung 2: no env, a declared poolPolicy.finality block resolves the value (fromDeclared).
    function test_Rung2_DeclaredOnly_FromPoolPolicy() public {
        string memory local = _localChain(5, "zz-scratch-ladder-declared-only");
        _declarePoolPolicy(local, "{\"finality\":{\"blockDepth\":\"5\",\"waitForSafe\":true}}");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertFalse(res.fromEnv, "no env rung");
        assertTrue(res.fromDeclared, "declared rung wins");
        assertEq(res.value, FinalityCodec.WAIT_FOR_SAFE_FLAG | bytes4(uint32(5)), "declared combined modes encoded");
        assertEq(bytes(res.hint).length, 0, "a declared-sourced value does not hint");

        _cleanupScratchOne(local);
    }

    /// Rung 2: an EMPTY declared block is declared-disabled (the WAIT_FOR_FINALITY default).
    function test_Rung2_DeclaredEmptyBlock_DeclaredDisabled() public {
        string memory local = _localChain(6, "zz-scratch-ladder-declared-empty");
        _declarePoolPolicy(local, "{\"finality\":{}}");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertTrue(res.fromDeclared, "an empty block is still a declaration");
        assertEq(res.value, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "declared-disabled resolves the default");

        _cleanupScratchOne(local);
    }

    /// Rung 3: neither env nor declaration resolves the WAIT_FOR_FINALITY reset - bit-identical to
    /// the historical env-only behavior for a project store with no poolPolicy block.
    function test_Rung3_Neither_ResetsToDefault() public {
        string memory local = _localChain(7, "zz-scratch-ladder-neither-reset");

        SetFinalityConfig.FinalityResolution memory res = harness.resolveFinality();

        assertFalse(res.fromEnv, "no env rung");
        assertFalse(res.fromDeclared, "no declared rung");
        assertEq(res.value, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "reset to the default");
        assertEq(bytes(res.notice).length, 0, "no notice");
        assertEq(bytes(res.hint).length, 0, "no hint");

        _cleanupScratchOne(local);
    }

    /// A declared blockDepth over the uint16 range reverts by name at parse time.
    function test_DeclaredOverRangeDepth_RevertsByName() public {
        string memory local = _localChain(8, "zz-scratch-ladder-over-range");
        _declarePoolPolicy(local, "{\"finality\":{\"blockDepth\":\"70000\"}}");

        vm.expectRevert(bytes(".poolPolicy.finality.blockDepth must be <= FinalityCodec.MAX_BLOCK_DEPTH (65535)"));
        harness.resolveFinality();

        _cleanupScratchOne(local);
    }
}
