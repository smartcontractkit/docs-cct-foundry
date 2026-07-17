// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {LaneReconcileScratch} from "./VerifyChainLaneReconcile.t.sol";
import {MockV2CcvPool, MockV161Pool} from "./VerifyChainCCVReconcile.t.sol";

/// @dev An UNCATALOGED typeAndVersion with the chain-membership getters but NO
///      `getAllowedFinalityConfig`: a declared `poolPolicy.finality` against it must degrade to the
///      unanswered-read WARN (best effort), never a FAIL or an aborted doctor run.
contract MockUnknownVersionNoFinalityPool {
    function typeAndVersion() external pure returns (string memory) {
        return "FancyForkPool 9.9.9";
    }

    function isSupportedChain(uint64) external pure returns (bool) {
        return false;
    }

    function getSupportedChains() external pure returns (uint64[] memory) {
        return new uint64[](0);
    }
}

/// @notice The `make doctor` pool-policy finality reconcile: the declared `poolPolicy.finality`
///         block ({blockDepth?, waitForSafe?}; `{}` declares the WAIT_FOR_FINALITY default) encoded
///         via FinalityConfigUtils and compared against the pool's live `getAllowedFinalityConfig`.
///         Drift and version-gate violations FAIL naming the field (with raw bytes4 plus decoded
///         labels on both sides of the drift message); an absent block is never reconciled;
///         unanswered reads on an uncataloged version stay WARN.
contract VerifyChainFinalityReconcileTest is LaneReconcileScratch {
    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[8] memory names = [
            "zz-scratch-finality-depth-match",
            "zz-scratch-finality-combined-match",
            "zz-scratch-finality-drift",
            "zz-scratch-finality-declared-disabled",
            "zz-scratch-finality-version-gate",
            "zz-scratch-finality-unknown-version",
            "zz-scratch-finality-over-range",
            "zz-scratch-finality-non-numeric"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            _cleanupScratchOne(names[i]);
        }
    }

    /// PASS: declared block depth matches the live config.
    function test_Finality_Pass_BlockDepthMatch() public {
        string memory name = "zz-scratch-finality-depth-match";
        _writeScratchChain(name, 887_600_101, 8_876_001_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0));
        pool.setAllowedFinality(bytes4(uint32(5))); // BLOCK_DEPTH (5 blocks)
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"5\"}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "a matching poolPolicy.finality must not FAIL");
        assertEq(warns, 0, "a matching poolPolicy.finality must not WARN");

        _cleanupScratchOne(name);
    }

    /// PASS: the combined declaration (waitForSafe + blockDepth) encodes the safe flag plus the
    /// depth, matching a live config that allows either mode.
    function test_Finality_Pass_CombinedSafeAndDepthMatch() public {
        string memory name = "zz-scratch-finality-combined-match";
        _writeScratchChain(name, 887_600_201, 8_876_002_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0));
        pool.setAllowedFinality(FinalityCodec.WAIT_FOR_SAFE_FLAG | bytes4(uint32(32)));
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"32\",\"waitForSafe\":true}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "a matching combined declaration must not FAIL");
        assertEq(warns, 0, "a matching combined declaration must not WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: the declared mode (safe tag) contradicts the live config (a block depth).
    function test_Finality_Fail_Drift() public {
        string memory name = "zz-scratch-finality-drift";
        _writeScratchChain(name, 887_600_301, 8_876_003_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0));
        pool.setAllowedFinality(bytes4(uint32(12))); // live: BLOCK_DEPTH (12 blocks)
        _declarePoolPolicy(name, "{\"finality\":{\"waitForSafe\":true}}"); // declared: WAIT_FOR_SAFE

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "poolPolicy.finality drift must FAIL naming the field");
        assertEq(warns, 0, "finality drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// The declared-disabled contract: an EMPTY finality block declares the WAIT_FOR_FINALITY
    /// default (fast finality off) - quiet against a live 0x00000000, one FAIL against a live
    /// faster mode.
    function test_Finality_DeclaredDisabled_MatchThenDrift() public {
        string memory name = "zz-scratch-finality-declared-disabled";
        _writeScratchChain(name, 887_600_401, 8_876_004_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0)); // live defaults to 0x00000000
        _declarePoolPolicy(name, "{\"finality\":{}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "declared-disabled matching live WAIT_FOR_FINALITY must not FAIL");
        assertEq(warns, 0, "declared-disabled matching live WAIT_FOR_FINALITY must not WARN");

        pool.setAllowedFinality(FinalityCodec.WAIT_FOR_SAFE_FLAG); // live loosened out-of-band
        (fails, warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "a live faster mode against a declared-disabled block must FAIL");
        assertEq(warns, 0, "the declared-disabled drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: poolPolicy.finality declared against a CATALOGED pre-2.0.0 pool - the allowed-finality
    /// surface is 2.0.0-only, so the version gate FAILs by name and never attempts a read.
    function test_Finality_Fail_OnCataloged1xPool() public {
        string memory name = "zz-scratch-finality-version-gate";
        _writeScratchChain(name, 887_600_501, 8_876_005_010_000_000_001);
        MockV161Pool pool = new MockV161Pool();
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"5\"}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "poolPolicy.finality on a cataloged 1.x pool must FAIL the version gate");
        assertEq(warns, 0, "the version-gate FAIL must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// WARN: an uncataloged version that does not answer getAllowedFinalityConfig - best effort per
    /// the reads-degrade doctrine (the unknown-version notice plus the unanswered-read WARN).
    function test_Finality_Warn_UnknownVersionUnansweredRead() public {
        string memory name = "zz-scratch-finality-unknown-version";
        _writeScratchChain(name, 887_600_601, 8_876_006_010_000_000_001);
        MockUnknownVersionNoFinalityPool pool = new MockUnknownVersionNoFinalityPool();
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"5\"}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 0, "an unanswered finality read must never FAIL");
        assertEq(warns, 2, "the unknown-version notice plus the unanswered-read WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: a malformed declaration (blockDepth over the uint16 range) is a named declaration
    /// error, never an aborted doctor run.
    function test_Finality_Fail_MalformedOverRangeDepth() public {
        string memory name = "zz-scratch-finality-over-range";
        _writeScratchChain(name, 887_600_701, 8_876_007_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0));
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"70000\"}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "an over-range blockDepth must FAIL naming the declaration");
        assertEq(warns, 0, "the malformed declaration must not additionally WARN");

        _cleanupScratchOne(name);
    }

    /// FAIL: a NON-NUMERIC blockDepth (a raw cheatcode parse revert, not an Error(string)) still
    /// degrades to the named malformed-declaration FAIL through the probe's generic catch - never
    /// an aborted doctor run.
    function test_Finality_Fail_MalformedNonNumericDepth() public {
        string memory name = "zz-scratch-finality-non-numeric";
        _writeScratchChain(name, 887_600_801, 8_876_008_010_000_000_001);
        MockV2CcvPool pool = new MockV2CcvPool(0, address(0));
        _declarePoolPolicy(name, "{\"finality\":{\"blockDepth\":\"not-a-number\"}}");

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(pool));
        assertEq(fails, 1, "a non-numeric blockDepth must FAIL naming the declaration");
        assertEq(warns, 0, "the malformed declaration must not additionally WARN");

        _cleanupScratchOne(name);
    }
}
