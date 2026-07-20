// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {UpdateTokenTransferFeeConfig} from "../../script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev Exposes UpdateTokenTransferFeeConfig's per-field input resolution with the env access
///      swapped for an injectable fake (the `_env*` seams exist for exactly this: env vars are
///      process-global and forge runs suites in parallel, so tests must never vm.setEnv shared
///      names). An unset fake var behaves like an unset env var; the resolution logic under test is
///      unmodified. The current on-chain config is a parameter because run() reads it from the pool
///      before resolving - the rung-3 fallback needs no fork to trust.
contract FeeConfigLaneSourceHarness is UpdateTokenTransferFeeConfig {
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

    function resolve(
        IPoolV2.TokenTransferFeeConfig memory currentConfig,
        string memory destChainName,
        uint64 destChainSelector
    ) external view returns (FeeConfigResolution memory) {
        return _resolveFeeConfig(currentConfig, destChainName, destChainSelector);
    }

    /// @dev Builds the broadcast args from a fully-resolved field-value vector, exercising the
    ///      per-field range/downcast guards without needing the on-chain read or the ladder.
    function build(uint256[6] memory values, uint64 destChainSelector)
        external
        pure
        returns (TokenPool.TokenTransferFeeConfigArgs[] memory)
    {
        FeeConfigResolution memory res;
        for (uint256 i = 0; i < 6; i++) {
            res.fields[i].value = values[i];
        }
        return _buildFeeConfigArgs(res, destChainSelector);
    }
}

/// @notice The per-field fee-config input ladder of UpdateTokenTransferFeeConfig (env > declared
///         `v2.feeConfig.<field>` > current on-chain value), proven offline against scratch chain
///         configs: rung-1 env byte-equality (agreeing, diverging - whole-block and single-field),
///         rung-2 lanes{} consumption (whole block, partial block with the on-chain fallback for
///         undeclared fields), the rung-3 historical default (current on-chain values, exactly the
///         script's pre-existing per-field `vm.envOr(name, current)` semantics), the partial-env
///         mix (env field wins, declared fields fill the rest), the selector-fallback lane match,
///         and the hand-edit hint states. Each test writes its own uniquely-named scratch chain and
///         pins block.chainid to that chain's declared chainId via vm.chainId (test-local, no
///         process-global state).
contract UpdateTokenTransferFeeConfigLaneSourceTest is LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_873_000_000_000_000_001;

    FeeConfigLaneSourceHarness internal harness;

    // Three disjoint value sets so every assertion proves its source rung unambiguously.
    uint256[6] internal ENV_VALUES = [uint256(50_000), 32, 10, 100, 5, 50];
    uint256[6] internal LANE_VALUES = [uint256(90_000), 64, 20, 200, 10, 25];
    uint256[6] internal CURRENT_VALUES = [uint256(70_000), 16, 30, 300, 15, 75];

    function setUp() public {
        _clean();
        harness = new FeeConfigLaneSourceHarness();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](10);
        for (uint256 n = 1; n <= 9; n++) {
            names[n - 1] = string.concat("zz-scratch-feesrc-l", vm.toString(n));
        }
        names[9] = "zz-scratch-feesrc-r1";
        _cleanupScratch(names);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Writes the local scratch chain and pins block.chainid to it, so the resolution's
    ///      local-config discovery finds exactly this file.
    function _localChain(uint256 n) internal returns (string memory name) {
        name = string.concat("zz-scratch-feesrc-l", vm.toString(n));
        uint256 chainId = 887_301_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_873_010_000_000_000_000 + n * 100 + 1));
        vm.chainId(chainId);
    }

    function _envNames() internal pure returns (string[6] memory) {
        return [
            string("DEST_GAS_OVERHEAD"),
            "DEST_BYTES_OVERHEAD",
            "FINALITY_FEE_USD_CENTS",
            "FAST_FINALITY_FEE_USD_CENTS",
            "FINALITY_TRANSFER_FEE_BPS",
            "FAST_FINALITY_TRANSFER_FEE_BPS"
        ];
    }

    function _fieldNames() internal pure returns (string[6] memory) {
        return [
            string("destGasOverhead"),
            "destBytesOverhead",
            "finalityFeeUSDCents",
            "fastFinalityFeeUSDCents",
            "finalityTransferFeeBps",
            "fastFinalityTransferFeeBps"
        ];
    }

    function _setAllEnv(uint256[6] memory values) internal {
        string[6] memory names = _envNames();
        for (uint256 i = 0; i < 6; i++) {
            harness.setFakeEnv(names[i], vm.toString(values[i]));
        }
    }

    /// @dev The current on-chain config the harness resolves against (rung 3).
    function _current() internal view returns (IPoolV2.TokenTransferFeeConfig memory cfg) {
        cfg.destGasOverhead = uint32(CURRENT_VALUES[0]);
        cfg.destBytesOverhead = uint32(CURRENT_VALUES[1]);
        cfg.finalityFeeUSDCents = uint32(CURRENT_VALUES[2]);
        cfg.fastFinalityFeeUSDCents = uint32(CURRENT_VALUES[3]);
        cfg.finalityTransferFeeBps = uint16(CURRENT_VALUES[4]);
        cfg.fastFinalityTransferFeeBps = uint16(CURRENT_VALUES[5]);
        cfg.isEnabled = true;
    }

    /// @dev A `,"v2":{"feeConfig":{...}}` suffix for `_laneEntry`, declaring the first
    ///      `declaredCount` fields (in the canonical field order) with `values` - 6 for a full
    ///      block, fewer for a partial one.
    function _feeBlock(uint256[6] memory values, uint256 declaredCount) internal pure returns (string memory) {
        string[6] memory fields = _fieldNames();
        string memory inner = "";
        for (uint256 i = 0; i < declaredCount; i++) {
            inner = string.concat(inner, i == 0 ? "" : ",", "\"", fields[i], "\":\"", vm.toString(values[i]), "\"");
        }
        return string.concat(",\"v2\":{\"feeConfig\":{", inner, "}}");
    }

    function _assertValues(
        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res,
        uint256[6] memory expected,
        string memory label
    ) internal pure {
        for (uint256 i = 0; i < 6; i++) {
            assertEq(res.fields[i].value, expected[i], string.concat(label, " field ", vm.toString(i)));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 1: env vars set
    // ─────────────────────────────────────────────────────────────────────────

    // All six env vars, no lanes{} entry: values identical to the historical env behavior, and the
    // hand-edit hint is armed naming the remote's config basename as the entry to declare.
    function test_EnvOnly_NoLaneEntry_EnvPinned_HintArmed() public {
        string memory local = _localChain(1);
        _writeScratchChain("zz-scratch-feesrc-r1", 887_301_901, 8_873_019_010_000_000_001);
        _setAllEnv(ENV_VALUES);

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-r1", REMOTE_SELECTOR);

        _assertValues(res, ENV_VALUES, "env value pinned");
        assertTrue(res.anyEnv, "env rung must trigger");
        assertFalse(res.laneFound, "no lane entry to find");
        assertTrue(res.configFound, "local config must be discovered");
        assertEq(res.configName, local, "wrong local config matched");
        assertEq(res.laneKey, "zz-scratch-feesrc-r1", "hint entry key must be the remote basename");
        assertFalse(res.anyDiverges, "no declared block, nothing to diverge from");
        assertTrue(res.editHint, "env apply with an undeclared block must hint");
        // Byte-exact pin of the composed closing hand-edit hint (undeclared block).
        assertEq(
            res.editHintText,
            string.concat(
                unicode"⚠️  Applied fee config is not declared in lanes.zz-scratch-feesrc-r1.v2.feeConfig (project/",
                local,
                ".json). Hand-edit the block to the applied values: destGasOverhead=",
                vm.toString(ENV_VALUES[0]),
                " destBytesOverhead=",
                vm.toString(ENV_VALUES[1]),
                " finalityFeeUSDCents=",
                vm.toString(ENV_VALUES[2]),
                " fastFinalityFeeUSDCents=",
                vm.toString(ENV_VALUES[3]),
                " finalityTransferFeeBps=",
                vm.toString(ENV_VALUES[4]),
                " fastFinalityTransferFeeBps=",
                vm.toString(ENV_VALUES[5]),
                " - make doctor CHAIN=",
                local,
                " FAILs until reconciled"
            ),
            "composed undeclared edit hint"
        );

        _cleanupScratchOne(local);
        vm.removeFile(_path("zz-scratch-feesrc-r1"));
    }

    // All six env vars + an AGREEING declared block: no divergence, no hint.
    function test_EnvAndBlockAgree_NoDivergence_NoHint() public {
        string memory local = _localChain(2);
        _declareLane(local, "zz-scratch-feesrc-remote2", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(ENV_VALUES, 6)));
        _setAllEnv(ENV_VALUES);

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote2", REMOTE_SELECTOR);

        _assertValues(res, ENV_VALUES, "env value pinned");
        assertTrue(res.laneFound && res.blockDeclared, "block must be found");
        assertFalse(res.anyDiverges, "agreeing env values must not flag divergence");
        assertFalse(res.editHint, "an agreeing declaration needs no hint");

        _cleanupScratchOne(local);
    }

    // All six env vars + a DIVERGING declared block: env wins, every field flags its
    // divergence, hint armed.
    function test_EnvAndBlockDiverge_EnvWins_DivergenceAndHint() public {
        string memory local = _localChain(3);
        _declareLane(local, "zz-scratch-feesrc-remote3", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 6)));
        _setAllEnv(ENV_VALUES);

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote3", REMOTE_SELECTOR);

        _assertValues(res, ENV_VALUES, "env value wins");
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(res.fields[i].fromEnv, "field must come from env");
            assertTrue(res.fields[i].diverges, "field must flag divergence");
            assertEq(res.fields[i].declaredValue, LANE_VALUES[i], "declared value parsed");
        }
        assertTrue(res.anyDiverges, "divergence must aggregate");
        assertTrue(res.editHint, "a diverging declaration must hint");
        // Byte-exact pin of the composed per-field divergence notice (field 0, destGasOverhead).
        assertEq(
            res.fieldNotices[0],
            string.concat(
                unicode"⚠️  DEST_GAS_OVERHEAD=",
                vm.toString(ENV_VALUES[0]),
                " diverges from declared lanes.zz-scratch-feesrc-remote3.v2.feeConfig.destGasOverhead=",
                vm.toString(LANE_VALUES[0]),
                " in project/",
                local,
                ".json - make doctor will FAIL until reconciled"
            ),
            "composed per-field divergence notice"
        );

        _cleanupScratchOne(local);
    }

    // PER-FIELD divergence: one env var set to a diverging value, the block declares all six -
    // only that field diverges (env wins for it), the other five resolve from the declaration.
    function test_PerField_SingleEnvDiverges_OthersFromLanes() public {
        string memory local = _localChain(4);
        _declareLane(local, "zz-scratch-feesrc-remote4", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 6)));
        harness.setFakeEnv("DEST_GAS_OVERHEAD", vm.toString(ENV_VALUES[0]));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote4", REMOTE_SELECTOR);

        assertEq(res.fields[0].value, ENV_VALUES[0], "env field must win");
        assertTrue(res.fields[0].fromEnv && res.fields[0].diverges, "only the env field diverges");
        for (uint256 i = 1; i < 6; i++) {
            assertEq(res.fields[i].value, LANE_VALUES[i], "unset fields must come from the declaration");
            assertTrue(res.fields[i].fromLanes, "unset field must be lanes-sourced");
            assertFalse(res.fields[i].diverges, "a lanes-sourced field cannot diverge");
        }
        assertTrue(res.editHint, "the diverging field must hint");

        _cleanupScratchOne(local);
    }

    // Partial env AGREEING with its declared field: env wins for the set field (no divergence),
    // the rest fill from the declaration - no hint anywhere.
    function test_PartialEnvAgrees_RestFromLanes_NoHint() public {
        string memory local = _localChain(5);
        _declareLane(local, "zz-scratch-feesrc-remote5", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 6)));
        harness.setFakeEnv("DEST_GAS_OVERHEAD", vm.toString(LANE_VALUES[0]));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote5", REMOTE_SELECTOR);

        _assertValues(res, LANE_VALUES, "declared values fill");
        assertTrue(res.fields[0].fromEnv, "set field must come from env");
        assertFalse(res.anyDiverges, "agreeing override must not diverge");
        assertFalse(res.editHint, "nothing diverges, no hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 2: env vars unset, v2.feeConfig declared
    // ─────────────────────────────────────────────────────────────────────────

    // No env, full declared block: the whole fee config comes from the declaration. No hint.
    function test_NoEnv_FullBlock_AllFromLanes() public {
        string memory local = _localChain(6);
        _declareLane(local, "zz-scratch-feesrc-remote6", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 6)));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote6", REMOTE_SELECTOR);

        _assertValues(res, LANE_VALUES, "declared value drives");
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(res.fields[i].fromLanes, "field must be lanes-sourced");
        }
        assertTrue(res.anyFromLanes, "lanes rung must aggregate");
        assertFalse(res.editHint, "a lanes{}-sourced apply is already consistent");

        _cleanupScratchOne(local);
    }

    // No env, PARTIAL declared block (first three fields): declared fields from the block, the
    // undeclared rest keep the current on-chain values - the historical per-field fallback.
    function test_NoEnv_PartialBlock_DeclaredFromLanes_RestFromCurrent() public {
        string memory local = _localChain(7);
        _declareLane(local, "zz-scratch-feesrc-remote7", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 3)));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote7", REMOTE_SELECTOR);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(res.fields[i].value, LANE_VALUES[i], "declared field must come from the block");
            assertTrue(res.fields[i].fromLanes, "declared field must be lanes-sourced");
        }
        for (uint256 i = 3; i < 6; i++) {
            assertEq(res.fields[i].value, CURRENT_VALUES[i], "undeclared field must keep the on-chain value");
            assertFalse(res.fields[i].fromLanes, "undeclared field is not lanes-sourced");
            assertFalse(res.fields[i].declared, "absent field must read as undeclared");
        }
        assertFalse(res.editHint, "no env override, no hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rung 3: neither env vars nor a declared block
    // ─────────────────────────────────────────────────────────────────────────

    // The default stands: every field keeps the current on-chain value
    // (zero when no config is stored yet) and nothing hints - the
    // `vm.envOr(name, current)` semantics.
    function test_NoEnv_NoBlock_CurrentOnChainDefaults_NoHint() public {
        string memory local = _localChain(8);
        _declareLane(local, "zz-scratch-feesrc-remote8", _laneEntry(REMOTE_SELECTOR, 0, 0, ""));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "zz-scratch-feesrc-remote8", REMOTE_SELECTOR);

        _assertValues(res, CURRENT_VALUES, "current on-chain value stands");
        assertFalse(res.anyEnv, "no env vars set");
        assertFalse(res.blockDeclared, "no v2.feeConfig block declared");
        assertFalse(res.anyFromLanes, "nothing lanes-sourced");
        assertFalse(res.editHint, "historical default needs no hint");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lane matching: selector fallback
    // ─────────────────────────────────────────────────────────────────────────

    // The lanes key names no config file and differs from the destination name, but the entry's
    // remoteSelector equals the destination selector: the selector fallback matches it and its
    // declared block drives the config.
    function test_SelectorFallback_MatchesWhenKeyNameDiffers() public {
        string memory local = _localChain(9);
        _declareLane(local, "zz-scratch-feesrc-ghost9", _laneEntry(REMOTE_SELECTOR, 0, 0, _feeBlock(LANE_VALUES, 6)));

        UpdateTokenTransferFeeConfig.FeeConfigResolution memory res =
            harness.resolve(_current(), "ZZ_FEESRC_NO_SUCH_ID", REMOTE_SELECTOR);

        assertTrue(res.laneFound, "remoteSelector equality must match the entry");
        assertEq(res.laneKey, "zz-scratch-feesrc-ghost9", "wrong lane key matched");
        _assertValues(res, LANE_VALUES, "declared value drives");

        _cleanupScratchOne(local);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-field range / downcast safety (guards a silently WRONG live fee)
    // ─────────────────────────────────────────────────────────────────────────

    // A uint32 field one over its width reverts by name before the downcast truncates it. The
    // resolved value is what is checked, so this covers both env- and lanes-sourced values.
    function test_Build_OverRangeUint32Field_RevertsByName() public {
        uint256 overUint32 = uint256(type(uint32).max) + 1;
        uint256[6] memory values; // destGasOverhead over range, the rest valid zero
        values[0] = overUint32;

        vm.expectRevert(
            bytes(
                string.concat(
                    "Fee-config field destGasOverhead=",
                    vm.toString(overUint32),
                    " is out of range [0-",
                    vm.toString(uint256(type(uint32).max)),
                    "]; fix the env var or the declared lanes{}.v2.feeConfig value"
                )
            )
        );
        harness.build(values, REMOTE_SELECTOR);
    }

    // A bps field at 10000 (the on-chain BPS_DIVIDER boundary) reverts by name; valid is [0-9999].
    function test_Build_OverRangeBpsField_RevertsByName() public {
        uint256[6] memory values; // finalityTransferFeeBps at the divider boundary, the rest valid
        values[4] = 10_000;

        vm.expectRevert(
            bytes(
                "Fee-config field finalityTransferFeeBps=10000 is out of range [0-9999]; fix the env var or the declared lanes{}.v2.feeConfig value"
            )
        );
        harness.build(values, REMOTE_SELECTOR);
    }
}
