// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {ForgeContext} from "../../src/base/ForgeContext.sol";
import {OutcomeLog} from "../../src/base/OutcomeLog.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

/// @dev Pins mode and Safe execution tier through the virtual seams. `vm.setEnv` is process-wide and
/// races the suites forge runs in parallel, so the overrides are the supported way in.
contract OutcomeHarness is EoaExecutor {
    string private s_mode;
    bool private immutable i_safeDirect;

    constructor(string memory mode, bool safeDirect) {
        s_mode = mode;
        i_safeDirect = safeDirect;
    }

    function _executionMode() internal view override returns (string memory) {
        return s_mode;
    }

    function _safeExecutesInThisRun() internal view override returns (bool) {
        return i_safeDirect;
    }

    function callsWereApplied() external view returns (bool) {
        return _callsWereApplied();
    }

    function logOutcome(string memory message) external view {
        _logOperationOutcome(message);
    }

    function outcomeLine(string memory message) external view returns (string memory) {
        return _outcomeLine(message);
    }

    // Never broadcast from a test.
    function _executeCalls(CctActions.Call[] memory) internal pure override {}
}

/// @title OutcomeClassification
/// @notice Which outcome a write script may report depends on what the executor did with the calls,
/// not on reaching the end of `run()`. `MODE=safe` writes a batch for the owners to sign and attempts
/// nothing on-chain; the EOA path and `SAFE_EXEC=direct` hand the calls to forge to send. These pin
/// that classification, which is the part a wrong answer makes a script lie about.
///
/// The two `NOT SENT` wordings are pinned as VALUES, through `_lineFor`, never as printed output:
/// forge intercepts the console staticcall, so `vm.expectCall` on it reports zero calls and asserting
/// on a printed line would pass vacuously. `SENDING` needs a broadcast context no test can enter.
contract OutcomeClassificationTest is Test {
    function test_EoaMode_CallsAreSubmitted() public {
        assertTrue(new OutcomeHarness("eoa", false).callsWereApplied(), "the EOA path hands calls to forge");
    }

    function test_SafeBatch_IsNotApplied() public {
        assertFalse(
            new OutcomeHarness("safe", false).callsWereApplied(), "a batch for the owners to sign attempts nothing"
        );
    }

    function test_SafeDirect_CallsAreSubmitted() public {
        assertTrue(new OutcomeHarness("safe", true).callsWereApplied(), "SAFE_EXEC=direct submits in this run");
    }

    /// The classifier is only useful through the line it selects. Testing `_callsWereApplied` alone
    /// left the routing unpinned: swapping its two branches made every write script report the
    /// opposite of what it did, with the whole suite green.
    function test_RoutingSelectsTheBatchLine() public {
        OutcomeHarness h = new OutcomeHarness("safe", false);
        assertEq(
            h.outcomeLine("set the pool"),
            unicode"📝 NOT SENT (Safe batch to sign): set the pool",
            "a Safe batch run must report the batch line"
        );
    }

    /// Under `forge test` forge reports neither ScriptBroadcast nor ScriptResume, so a non-batch run
    /// selects the dry-run line here. That is the branch a real `forge script` without `--broadcast`
    /// takes, and it is otherwise unreachable in-process.
    function test_RoutingSelectsTheDryRunLineWhenNothingWillBeSent() public {
        OutcomeHarness h = new OutcomeHarness("eoa", false);
        assertEq(
            h.outcomeLine("set the pool"),
            unicode"🔍 NOT SENT (simulation only, add --broadcast): set the pool",
            "nothing is sent under forge test, so the dry-run line is correct here"
        );
        assertTrue(ForgeContext._sendsNothing(), "and that is why: no broadcast context");
    }

    /// The wordings are the operator's whole signal, so they are pinned as values: forge intercepts the
    /// console staticcall, so a printed line cannot be observed by `vm.expectCall` or `recordLogs`.
    function test_TheNotSentWordingsAreStable() public view {
        // Only the two NOT SENT lines are reachable here: under `forge test` forge reports no broadcast
        // context, so no test pins the SENDING wording - only `_lineFor`'s own source carries it.
        assertEq(OutcomeLog._lineFor("X", false), unicode"📝 NOT SENT (Safe batch to sign): X");
        assertEq(OutcomeLog._lineFor("X", true), unicode"🔍 NOT SENT (simulation only, add --broadcast): X");
    }

    /// `SAFE_EXEC` decides both what the run DOES and what it SAYS, from one parse, so the two cannot
    /// drift into a run that submits while announcing a batch. Asserting the two callers against each
    /// other would be vacuous now that they share the function - so pin the vocabulary itself.
    /// Traverses the real env read rather than the overridden seam. `SAFE_EXEC` unset is the default
    /// every run starts from, so asserting it needs no `vm.setEnv` - which is process-wide and would
    /// race the suites forge runs in parallel.
    function test_RealEnvReadReachesTheParse() public {
        OutcomeHarnessRealEnv h = new OutcomeHarnessRealEnv("safe");
        assertFalse(h.safeExecutesInThisRun(), "SAFE_EXEC unset must not select the submit path");
        assertFalse(h.callsWereApplied(), "so an emit-only Safe run reports the batch, not a send");
    }

    /// The unset default is identical for every variable name, so the test above cannot tell
    /// `SAFE_EXEC` from a typo - mutating the name passed the whole suite. Setting the variable is not
    /// an option (`vm.setEnv` is process-wide and races the suites forge runs in parallel), so both
    /// readers take the name from one constant and this pins that.
    function test_TheEnvVariableNameIsSafeExec() public pure {
        assertEq(SafeMode.SAFE_EXEC_ENV, "SAFE_EXEC", "both readers take the name from here");
    }

    function test_SafeExecVocabulary() public pure {
        assertTrue(SafeMode._isDirect("direct"), "direct selects the submit path");
        assertFalse(SafeMode._isDirect(""), "unset emits a batch");
        assertFalse(SafeMode._isDirect("Direct"), "the comparison is exact, not case-folded");
        assertFalse(SafeMode._isDirect("dir3ct"), "a typo must not select the submit path");
    }
}

/// @dev Deliberately does NOT override `_safeExecutesInThisRun`, so the real
/// `EoaExecutor -> SafeMode._execsDirect -> envOr("SAFE_EXEC")` chain is traversed. Every other harness
/// overrides that seam, which left the wiring unexecuted: making `_execsDirect` read a different
/// variable passed the whole suite.
contract OutcomeHarnessRealEnv is EoaExecutor {
    string private s_mode;

    constructor(string memory mode) {
        s_mode = mode;
    }

    function _executionMode() internal view override returns (string memory) {
        return s_mode;
    }

    function safeExecutesInThisRun() external view returns (bool) {
        return _safeExecutesInThisRun();
    }

    function callsWereApplied() external view returns (bool) {
        return _callsWereApplied();
    }

    function _executeCalls(CctActions.Call[] memory) internal pure override {}
}
