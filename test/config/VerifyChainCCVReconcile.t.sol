// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {LaneReconcileScratch} from "./VerifyChainLaneReconcile.t.sol";

/// @dev A 2.0.0-shaped pool exposing exactly what the CCV reconcile reads: version, chain membership,
///      the (disabled) core rate-limit buckets, and its AdvancedPoolHooks address (settable, so the
///      no-hooks path is testable). No fastFinality/feeConfig surface is declared in these tests, so
///      only the core buckets and the CCV block are reconciled.
contract MockV2CcvPool {
    uint64 private immutable i_selector;
    address private immutable i_hooks;

    constructor(uint64 selector, address hooks) {
        i_selector = selector;
        i_hooks = hooks;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.0.0";
    }

    function isSupportedChain(uint64 selector) external view returns (bool) {
        return selector == i_selector;
    }

    function getSupportedChains() external view returns (uint64[] memory chains) {
        if (i_selector == 0) return new uint64[](0);
        chains = new uint64[](1);
        chains[0] = i_selector;
    }

    function getAdvancedPoolHooks() external view returns (address) {
        return i_hooks;
    }

    // Disabled core buckets (empty return): a lane declared 0/0 reconciles clean, isolating the CCV block.
    function getCurrentRateLimiterState(uint64, bool)
        external
        pure
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound)
    {}
}

/// @dev A pre-2.0.0 pool (1.6.1): the reconcile's chain-level ccvThreshold check has a distinct
///      version-named WARN branch for a pool that predates the AdvancedPoolHooks surface (never a read
///      attempt, never a FAIL). Answers getSupportedChains for the reverse check.
contract MockV161Pool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.6.1";
    }

    function isSupportedChain(uint64) external pure returns (bool) {
        return false;
    }

    function getSupportedChains() external pure returns (uint64[] memory) {
        return new uint64[](0);
    }
}

/// @notice The `make doctor` CCV reconcile: the declared `lanes.<remote>.v2.ccv` verifier arrays and
///         the chain-level `ccvThreshold` compared against the pool's AdvancedPoolHooks, WARN-only.
///         Set-insensitive (a reordered verifier set is not drift); a `v2.ccv` block against a pool
///         with no hooks is a version-mismatch-style WARN, never a read attempt or a FAIL.
contract VerifyChainCCVReconcileTest is LaneReconcileScratch {
    uint64 internal constant SEL = 8_875_000_000_000_000_001;
    address internal constant A1 = address(0xA001);
    address internal constant A2 = address(0xA002);

    function setUp() public {
        string[] memory names = new string[](6);
        for (uint256 n = 1; n <= 6; n++) {
            names[n - 1] = string.concat("zz-scratch-ccvchk-", vm.toString(n));
        }
        _cleanupScratch(names);
    }

    function _deployHooks(uint256 threshold) internal returns (AdvancedPoolHooks hooks) {
        address[] memory authorizedCallers = new address[](1);
        authorizedCallers[0] = address(this);
        hooks = new AdvancedPoolHooks(new address[](0), threshold, address(0), authorizedCallers);
    }

    function _setCcv(AdvancedPoolHooks hooks, address[] memory outbound, address[] memory inbound) internal {
        AdvancedPoolHooks.CCVConfigArg[] memory args = new AdvancedPoolHooks.CCVConfigArg[](1);
        args[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: SEL,
            outboundCCVs: outbound,
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: inbound,
            thresholdInboundCCVs: new address[](0)
        });
        hooks.applyCCVConfigUpdates(args);
    }

    function _arr2(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ccvBlock(string memory outboundJson) internal pure returns (string memory) {
        return string.concat(",\"v2\":{\"ccv\":{\"outboundCCVs\":", outboundJson, "}}");
    }

    /// PASS: the declared CCV set equals the on-chain set in a DIFFERENT ORDER (set-insensitive).
    function test_CCV_Pass_SetInsensitive() public {
        string memory name = "zz-scratch-ccvchk-1";
        _writeScratchChain(name, 887_500_101, 8_875_001_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(0);
        _setCcv(hooks, _arr2(A1, A2), new address[](0));
        MockV2CcvPool pool = new MockV2CcvPool(SEL, address(hooks));
        // declare outbound as [A2, A1] (reversed) + core buckets 0/0 (disabled, matches the mock)
        string memory ccv = _ccvBlock(string.concat("[\"", vm.toString(A2), "\",\"", vm.toString(A1), "\"]"));
        _declareLane(name, "zz-scratch-ccvchk-r1", _laneEntry(SEL, 0, 0, ccv));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "CCV reconcile must never FAIL");
        assertEq(warns, 0, "a reordered but equal CCV set must not WARN");

        vm.removeFile(_path(name));
    }

    /// WARN: the declared CCV set differs from on-chain.
    function test_CCV_Warn_ArrayDrift() public {
        string memory name = "zz-scratch-ccvchk-2";
        _writeScratchChain(name, 887_500_201, 8_875_002_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(0);
        _setCcv(hooks, _arr2(A1, A2), new address[](0));
        MockV2CcvPool pool = new MockV2CcvPool(SEL, address(hooks));
        // declare only [A1] -> differs from on-chain [A1, A2]
        string memory ccv = _ccvBlock(string.concat("[\"", vm.toString(A1), "\"]"));
        _declareLane(name, "zz-scratch-ccvchk-r2", _laneEntry(SEL, 0, 0, ccv));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "CCV drift is a WARN, never a FAIL");
        assertEq(warns, 1, "CCV outbound drift must emit exactly one WARN");

        vm.removeFile(_path(name));
    }

    /// WARN: a v2.ccv block against a 2.0.0 pool with NO hooks wired (address(0)).
    function test_CCV_Warn_NoHooks() public {
        string memory name = "zz-scratch-ccvchk-3";
        _writeScratchChain(name, 887_500_301, 8_875_003_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(SEL, address(0));
        string memory ccv = _ccvBlock(string.concat("[\"", vm.toString(A1), "\"]"));
        _declareLane(name, "zz-scratch-ccvchk-r3", _laneEntry(SEL, 0, 0, ccv));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "no-hooks CCV is a WARN, never a FAIL");
        assertEq(warns, 1, "a v2.ccv block with no hooks must emit exactly one WARN");

        vm.removeFile(_path(name));
    }

    /// WARN: a chain-level ccvThreshold that differs from the pool's on-chain threshold.
    function test_CCV_Warn_ThresholdDrift() public {
        string memory name = "zz-scratch-ccvchk-4";
        _writeScratchChain(name, 887_500_401, 8_875_004_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(500); // on-chain threshold 500
        // selector 0 -> the pool advertises no on-chain lanes, isolating the chain-level threshold check
        MockV2CcvPool pool = new MockV2CcvPool(0, address(hooks));
        vm.writeJson("999", _path(name), ".ccvThreshold"); // declared 999 != 500

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "threshold drift is a WARN, never a FAIL");
        assertEq(warns, 1, "a diverging ccvThreshold must emit exactly one WARN");

        vm.removeFile(_path(name));
    }

    /// WARN: a chain-level ccvThreshold declared against a PRE-2.0.0 pool. The threshold surface
    /// (AdvancedPoolHooks) is 2.0.0-only, so the reconcile emits a distinct version-named WARN and never
    /// attempts a read - and never FAILs. MockV2CcvPool (always 2.0.0) never reaches this branch.
    function test_CCV_Warn_ThresholdPre200Pool() public {
        string memory name = "zz-scratch-ccvchk-5";
        _writeScratchChain(name, 887_500_501, 8_875_005_010_000_000_001);
        MockV161Pool pool = new MockV161Pool();
        vm.writeJson("777", _path(name), ".ccvThreshold"); // declared threshold on a pre-2.0.0 pool

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "a ccvThreshold on a pre-2.0.0 pool is a WARN, never a FAIL");
        assertEq(warns, 1, "a ccvThreshold on a pre-2.0.0 pool must emit exactly one WARN");

        vm.removeFile(_path(name));
    }
}
