// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {LaneReconcileScratch, MockV1Pool} from "./VerifyChainLaneReconcile.t.sol";

/// @dev A 2.0.0-shaped pool exposing exactly what the CCV and pool-policy reconciles read: version,
///      chain membership, the (disabled) core rate-limit buckets, its AdvancedPoolHooks address
///      (settable, so the no-hooks path is testable), and a settable allowed-finality config (for
///      the poolPolicy.finality reconcile). No fastFinality/feeConfig surface is declared in these
///      tests, so only the declared blocks are reconciled.
contract MockV2CcvPool {
    uint64 private immutable i_selector;
    address private immutable i_hooks;
    bytes4 private s_allowedFinality;

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

    function setAllowedFinality(bytes4 config) external {
        s_allowedFinality = config;
    }

    function getAllowedFinalityConfig() external view returns (bytes4) {
        return s_allowedFinality;
    }

    // Disabled core buckets (empty return): a lane declared 0/0 reconciles clean, isolating the CCV block.
    function getCurrentRateLimiterState(uint64, bool)
        external
        pure
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound)
    {}
}

/// @dev A pre-2.0.0 pool (1.6.1): a pool-scoped policy declaration against it hits the version gate
///      (FAIL by name for a cataloged 1.x version, never a read attempt). Answers getSupportedChains
///      for the reverse check.
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
///         the pool-scoped `poolPolicy.ccvThreshold` compared against the pool's AdvancedPoolHooks.
///         Set-insensitive (a reordered verifier set is not drift); a mismatching set, a drifted
///         threshold, a declaration against a hooks-less 2.0.0 pool, and a declaration against a
///         cataloged 1.x pool are all FAILs naming the field or the fix; unanswered reads stay WARN.
contract VerifyChainCCVReconcileTest is LaneReconcileScratch {
    uint64 internal constant SEL = 8_875_000_000_000_000_001;
    address internal constant A1 = address(0xA001);
    address internal constant A2 = address(0xA002);

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](7);
        for (uint256 n = 1; n <= 7; n++) {
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

        _cleanupScratchOne(name);
    }

    /// FAIL: the declared CCV set differs from on-chain (a drifted verifier set silently changes
    /// what attestations the lane requires - the doctor must go red naming the array).
    function test_CCV_Fail_ArrayDrift() public {
        string memory name = "zz-scratch-ccvchk-2";
        _writeScratchChain(name, 887_500_201, 8_875_002_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(0);
        _setCcv(hooks, _arr2(A1, A2), new address[](0));
        MockV2CcvPool pool = new MockV2CcvPool(SEL, address(hooks));
        // declare only [A1] -> differs from on-chain [A1, A2]
        string memory ccv = _ccvBlock(string.concat("[\"", vm.toString(A1), "\"]"));
        _declareLane(name, "zz-scratch-ccvchk-r2", _laneEntry(SEL, 0, 0, ccv));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "CCV outbound drift must FAIL naming the array");
        assertEq(warns, 0, "CCV drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: a v2.ccv block against a 2.0.0 pool with NO hooks wired (address(0)) - the declaration
    /// can never converge until hooks are wired or the block is removed.
    function test_CCV_Fail_NoHooks() public {
        string memory name = "zz-scratch-ccvchk-3";
        _writeScratchChain(name, 887_500_301, 8_875_003_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(SEL, address(0));
        string memory ccv = _ccvBlock(string.concat("[\"", vm.toString(A1), "\"]"));
        _declareLane(name, "zz-scratch-ccvchk-r3", _laneEntry(SEL, 0, 0, ccv));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "a v2.ccv block with no hooks must FAIL naming the fix");
        assertEq(warns, 0, "the no-hooks FAIL must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: a declared poolPolicy.ccvThreshold that differs from the pool's on-chain threshold.
    function test_CCV_Fail_ThresholdDrift() public {
        string memory name = "zz-scratch-ccvchk-4";
        _writeScratchChain(name, 887_500_401, 8_875_004_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(500); // on-chain threshold 500
        // selector 0 -> the pool advertises no on-chain lanes, isolating the pool-scoped threshold check
        MockV2CcvPool pool = new MockV2CcvPool(0, address(hooks));
        _declarePoolPolicy(name, "{\"ccvThreshold\":\"999\"}"); // declared 999 != 500

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "a diverging poolPolicy.ccvThreshold must FAIL naming the field");
        assertEq(warns, 0, "threshold drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// PASS: a declared poolPolicy.ccvThreshold matching the pool's on-chain threshold is quiet.
    function test_CCV_Pass_ThresholdMatch() public {
        string memory name = "zz-scratch-ccvchk-6";
        _writeScratchChain(name, 887_500_601, 8_875_006_010_000_000_001);
        AdvancedPoolHooks hooks = _deployHooks(500);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(hooks));
        _declarePoolPolicy(name, "{\"ccvThreshold\":\"500\"}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "a matching poolPolicy.ccvThreshold must not FAIL");
        assertEq(warns, 0, "a matching poolPolicy.ccvThreshold must not WARN");

        _cleanupScratchOne(name);
    }

    /// WARN: a poolPolicy.ccvThreshold declared against an UNCATALOGED version. The gate degrades
    /// to a WARN (no hooks read attempted) next to the general unknown-version notice - never a
    /// FAIL, never an aborted run.
    function test_CCV_Warn_ThresholdOnUnknownVersion() public {
        string memory name = "zz-scratch-ccvchk-7";
        _writeScratchChain(name, 887_500_701, 8_875_007_010_000_000_001);
        MockV1Pool pool = new MockV1Pool("FancyForkPool 9.9.9", 0);
        _declarePoolPolicy(name, "{\"ccvThreshold\":\"777\"}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "a ccvThreshold on an uncataloged version must never FAIL");
        assertEq(warns, 2, "the unknown-version notice plus the threshold gate WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: a poolPolicy.ccvThreshold declared against a CATALOGED PRE-2.0.0 pool. The threshold
    /// surface (AdvancedPoolHooks) is 2.0.0-only, so the declaration can never converge on this
    /// pool: the version gate FAILs by name and never attempts a read. MockV2CcvPool (always 2.0.0)
    /// never reaches this branch.
    function test_CCV_Fail_ThresholdOnCataloged1xPool() public {
        string memory name = "zz-scratch-ccvchk-5";
        _writeScratchChain(name, 887_500_501, 8_875_005_010_000_000_001);
        MockV161Pool pool = new MockV161Pool();
        _declarePoolPolicy(name, "{\"ccvThreshold\":\"777\"}"); // declared threshold on a 1.6.1 pool

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "a poolPolicy.ccvThreshold on a cataloged 1.x pool must FAIL the version gate");
        assertEq(warns, 0, "the version-gate FAIL must not additionally WARN");

        _cleanupScratchOne(name);
    }
}
