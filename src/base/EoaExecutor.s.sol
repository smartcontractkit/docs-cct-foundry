// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CctActions} from "../actions/CctActions.sol";
import {SafeMode} from "./SafeMode.sol";
import {OutcomeLog} from "./OutcomeLog.sol";

/// @title EoaExecutor
/// @notice The execution entry point of the action layer: takes the `Call[]` a `CctActions` builder
///         produced and hands it to the executor the `MODE` environment variable selects. `MODE`
///         unset (or `eoa`, the default) broadcasts each call in order from the script signer -
///         today's behavior, unchanged. `MODE=safe` routes the IDENTICAL `Call[]` to the Safe
///         executor (`SafeMode`): the batch is emitted for review/signing instead of broadcast.
///         Scripts inherit this instead of calling contracts inline, so the calldata a user reviews
///         is exactly the calldata the action layer built, whichever mode executes it.
abstract contract EoaExecutor is Script {
    /// @notice Executes the calls in the mode `MODE` selects (default `eoa`). Virtual so tests can
    ///         capture the built calls without broadcasting or writing batch artifacts.
    function _executeCalls(CctActions.Call[] memory calls) internal virtual {
        string memory mode = _executionMode();
        if (SafeMode._isEoaMode(mode)) {
            _broadcastCalls(calls);
        } else if (SafeMode._isSafeMode(mode)) {
            SafeMode._run(calls);
        } else {
            revert(string.concat("Unknown MODE '", mode, "': use 'eoa' (default) or 'safe'."));
        }
    }

    /// @notice The execution mode, from the `MODE` environment variable (default `eoa`). Virtual so
    ///         tests can pin a mode without mutating the process-wide environment.
    function _executionMode() internal view virtual returns (string memory) {
        return vm.envOr("MODE", string("eoa"));
    }

    /// @notice The account that will EXECUTE the calls in the selected mode: the Safe in `safe`
    ///         mode, the script broadcaster otherwise. Preflight checks that assert on-chain
    ///         authority (owner, pending administrator, admin role) must compare against THIS
    ///         account - comparing against `_broadcaster()` wrongly rejects Safe-mode runs, where the
    ///         broadcaster only emits or submits and the Safe is the account acting on-chain.
    function _executingAccount() internal returns (address) {
        if (SafeMode._isSafeMode(_executionMode())) {
            return vm.envAddress("SAFE_ADDRESS");
        }
        return _broadcaster();
    }

    /// @notice Report the outcome of the operation the wrapper just handled. Call this instead of
    ///         printing a success line: what a run may truthfully claim depends on which executor took
    ///         the calls.
    /// @dev Three outcomes, because three different things can have happened: `MODE=safe` without
    ///      `SAFE_EXEC=direct` wrote a batch for the owners to sign and attempted nothing on-chain,
    ///      forge ran the body without `--broadcast` and discarded the calls, or the calls went to
    ///      forge to send. Not even the last one can claim a landed transaction - `OutcomeLog` carries
    ///      the mechanism and what does confirm the state.
    function _logOperationOutcome(string memory message) internal view {
        console.log(_outcomeLine(message));
    }

    /// @notice The line `_logOperationOutcome` would print. Separated so a test can assert BOTH the
    ///         wording and the selection: forge intercepts the console staticcall, so a printed line
    ///         cannot be observed in-process and swapping the two branches below would otherwise be
    ///         invisible to every test.
    function _outcomeLine(string memory message) internal view returns (string memory) {
        return OutcomeLog._lineFor(message, _callsWereApplied());
    }

    /// @notice Whether `_executeCalls` handed the calls to forge to send, as opposed to producing a
    ///         batch for the owners to sign.
    function _callsWereApplied() internal view returns (bool) {
        if (SafeMode._isSafeMode(_executionMode())) {
            return _safeExecutesInThisRun();
        }
        return true;
    }

    /// @notice Whether a Safe-routed run submits the transaction itself (`SAFE_EXEC=direct`) rather
    ///         than emitting a batch for the owners to sign later.
    function _safeExecutesInThisRun() internal view virtual returns (bool) {
        return SafeMode._execsDirect();
    }

    /// @notice The EOA mode: broadcasts every call in order, reverting on the first failure (atomic
    ///         batch semantics - a dry run surfaces the revert before anything is sent).
    function _broadcastCalls(CctActions.Call[] memory calls) private {
        vm.startBroadcast();
        for (uint256 i = 0; i < calls.length; i++) {
            console.log(
                string.concat(
                    "  Queueing call ",
                    vm.toString(i + 1),
                    "/",
                    vm.toString(calls.length),
                    ": target ",
                    vm.toString(calls[i].target),
                    " selector ",
                    vm.toString(abi.encodePacked(bytes4(calls[i].data)))
                )
            );
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) {
                // Bubble up the underlying contract's revert reason unchanged.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
        vm.stopBroadcast();
    }

    /// @notice Resolves the account the script will broadcast with (keystore --account, --private-key,
    ///         or the default sender), so wrappers can run their preflight checks against it before any
    ///         transaction is sent.
    function _broadcaster() internal returns (address account) {
        vm.startBroadcast();
        (, account,) = vm.readCallers();
        vm.stopBroadcast();
    }
}
