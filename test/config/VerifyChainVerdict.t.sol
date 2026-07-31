// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";

/// @title VerifyChainVerdictTest - the doctor's three-outcome contract
/// @notice The doctor returns VERIFIED / INCOMPLETE / FAILED, not a boolean. The state this pins is
/// INCOMPLETE: a run whose declared or deployed checks could not run (an unset RPC, a contract that
/// did not answer) must not exit clean (the rationale lives on `_verdict`). Designed absences (non-EVM
/// rungs, undeclared optional blocks) stay plain SKIPs and never taint the verdict: there, nothing
/// claimable was left unchecked. Driven through `verdictForTest`, which seeds the counters exactly as
/// the rungs do; the full-run path (rpcEnv unset -> nonzero exit) is exercised by
/// `script/config/test-tooling.sh`.
contract VerifyChainVerdictTest is Test {
    string internal constant NAME = "zz-tt-verdict";

    function test_Verdict_NothingSkipped_IsVerified() public {
        new VerifyChain().verdictForTest(NAME, false, false, false);
    }

    function test_Verdict_DesignedSkip_StaysVerified() public {
        new VerifyChain().verdictForTest(NAME, true, false, false);
    }

    function test_Verdict_UnverifiedGap_IsIncompleteNotClean() public {
        try new VerifyChain().verdictForTest(NAME, false, true, false) {
            assertTrue(false, "a run with an unverified gap must not exit clean");
        } catch Error(string memory reason) {
            _assertContains(reason, string.concat("check-chain INCOMPLETE for ", NAME));
        }
    }

    /// @dev A genuine failure outranks incompleteness: the operator fixes the FAIL first, and the
    ///      gap resurfaces on the re-run.
    function test_Verdict_FailWithGap_IsFailedNotIncomplete() public {
        try new VerifyChain().verdictForTest(NAME, false, true, true) {
            assertTrue(false, "a run with a failure must not exit clean");
        } catch Error(string memory reason) {
            _assertContains(reason, string.concat("check-chain FAILED for ", NAME));
        }
    }

    /// @dev Pins each RPC-gated site individually: registry TAR reconcile, roles rung, lanes rung.
    ///      A regression demoting any of them back to a designed skip changes the count.
    function test_RpcGatedRungs_EachCountsOneUnverifiedGap() public {
        uint256 skips = new VerifyChain()
            .rpcGatedSkipsForTest('{"roles":{"token":{"address":"0x0000000000000000000000000000000000000001"}}}');
        assertEq(skips, 3, "registry TAR, roles, and lanes each count one unverified gap without an RPC");
    }

    function _assertContains(string memory haystack, string memory needle) internal pure {
        assertTrue(_contains(haystack, needle), string.concat("expected \"", needle, "\" in: ", haystack));
    }

    function _contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
