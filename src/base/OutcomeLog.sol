// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {ForgeContext} from "./ForgeContext.sol";

/// @title OutcomeLog
/// @notice What a write script may truthfully say it did, in one place so the broadcast path and the
///         deploy scripts cannot drift apart.
/// @dev No line printed from a script body can report a landed transaction. `forge script` runs the
///      body as a SIMULATION and dispatches the recorded calls only after it returns, so a stale
///      nonce or a dropped connection leaves the operation undone with the line already on screen.
///      That is what the checkmark these replace got wrong: it reported the intent as the outcome.
///      Each outcome below is true at the moment it prints and none of them claims the chain agrees -
///      forge's exit code is the authority on the send, and the state is confirmed by reading it back
///      (`make doctor`, or the matching `Get*` script).
///
///      Callers pass a VERB PHRASE naming the operation ("set the pool on the TokenAdminRegistry"),
///      never a past-tense claim: the prefix supplies the tense, and "set successfully!" inside a
///      line that says unconfirmed argues with itself.
///
///      The two that send nothing share the `NOT SENT` stem and differ by cause, because the operator
///      question is the same in both ("why is nothing happening?") while the next step is not. They
///      carry distinct glyphs so a scrolling terminal separates them at a glance.
library OutcomeLog {
    /// @notice The calls reached forge to send - or, when nothing will be sent, reported as such.
    /// @dev Named for what it can claim: not that anything was submitted, only that it was handed over.
    function _sending(string memory message) internal view {
        console.log(_lineFor(message, true));
    }

    /// @notice The line a run may truthfully print, given whether its executor handed the calls to
    ///         forge. The ONLY way to reach the sending and dry-run wordings, so neither can be printed
    ///         without the context check: announcing a dry run during a real broadcast, or a send
    ///         during a dry run, are both the mirror of the bug this file exists to prevent.
    /// @dev Returns the line rather than printing it because forge intercepts the console staticcall
    ///      before any inspector records it - `vm.expectCall` and `vm.recordLogs` cannot observe a
    ///      printed line, so a test can only pin wording and selection through a value.
    function _lineFor(string memory message, bool callsReachedForge) internal view returns (string memory) {
        if (!callsReachedForge) return _batchedLine(message);
        return ForgeContext._sendsNothing() ? _simulatedLine(message) : _sendingLine(message);
    }

    /// @dev The line for calls handed to forge to send.
    function _sendingLine(string memory message) private pure returns (string memory) {
        return string.concat(unicode"⏳ SENDING (unconfirmed): ", message);
    }

    /// @dev The line for a dry run: forge ran the body without `--broadcast` and sent nothing.
    function _simulatedLine(string memory message) private pure returns (string memory) {
        return string.concat(unicode"🔍 NOT SENT (simulation only, add --broadcast): ", message);
    }

    /// @dev The line for a batch written for the Safe owners to sign. No context check: the batch is
    ///      written whatever forge would do.
    function _batchedLine(string memory message) private pure returns (string memory) {
        return string.concat(unicode"📝 NOT SENT (Safe batch to sign): ", message);
    }
}
