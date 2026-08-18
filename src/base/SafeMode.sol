// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {OutcomeLog} from "./OutcomeLog.sol";
import {CctActions} from "../actions/CctActions.sol";
import {ISafe, IMultiSendCallOnly, SafeCanonical} from "./ISafe.sol";
import {SafeBatchEmitter} from "./SafeBatchEmitter.sol";
import {SafeTxHash} from "./SafeTxHash.sol";

/// @title SafeMode
/// @notice The Safe execution mode of the action layer (`MODE=safe`). Takes the IDENTICAL `Call[]` the
///         EOA mode would broadcast and, instead of broadcasting it, (1) logs every call for review,
///         (2) emits a Safe Transaction Builder JSON batch under `batches/`, and (3) optionally
///         (`SAFE_EXEC=direct`) executes the batch on the Safe via `execTransaction` with raw ECDSA
///         owner signatures - the universal path that needs no hosted Safe Transaction Service.
///
///         Environment variables (read only when `MODE=safe`):
///         - `SAFE_ADDRESS`      (required) the Safe that owns/administers the targets.
///         - `BATCH_NAME`        (optional) batch file basename; default `cct-batch`.
///         - `SAFE_EXEC`         (optional) unset/empty = emit the batch only (sign via the Safe{Wallet}
///                               UI or `safe-cli`); `direct` = execute `execTransaction` now.
///         - `SAFE_SIGNER_KEYS`  (required for `SAFE_EXEC=direct`) comma-separated owner private keys;
///                               at least `threshold` of them. Never logged.
/// @dev Review-before-submit is the security gate: the batch JSON (and the logged decode) must be
///      verified against the intended operation BEFORE any signature is produced, and the local
///      EIP-712 `safeTxHash` recompute must equal the Safe's on-chain `getTransactionHash` - both are
///      enforced here, in that order.
library SafeMode {
    /// @dev The env var selecting the direct-submit path. Named once: `_run` reads it to decide what
    ///      to do and to build its error, `_execsDirect` reads it to decide what the run may claim,
    ///      and a wrong name in either silently means "not direct".
    string internal constant SAFE_EXEC_ENV = "SAFE_EXEC";

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Emit the Transaction Builder batch for `calls` (and execute it when `SAFE_EXEC=direct`).
    /// @return path the batch JSON file written under `batches/`.
    function _run(CctActions.Call[] memory calls) internal returns (string memory path) {
        address safe = VM.envAddress("SAFE_ADDRESS");
        string memory batchName = VM.envOr("BATCH_NAME", string("cct-batch"));

        path = _emitBatch(batchName, safe, calls);

        string memory execMode = VM.envOr(SAFE_EXEC_ENV, string(""));
        if (bytes(execMode).length == 0) {
            console.log("  Next: import into the Safe{Wallet} Transaction Builder, or propose via safe-cli.");
        } else if (_isDirect(execMode)) {
            _execDirect(ISafe(safe), calls);
        } else {
            revert(
                string.concat("SafeMode: unknown ", SAFE_EXEC_ENV, " '", execMode, "' (use 'direct' or leave unset).")
            );
        }
    }

    /// @notice Whether `MODE` selects the Safe executor. One comparison, because three callers act on
    ///         it: `_executeCalls` decides what runs, `_executingAccount` decides whose authority is
    ///         checked, and `_callsWereApplied` decides what the run may claim. Written out three times
    ///         they can disagree, and the third one deciding wrongly is a script reporting an outcome
    ///         that did not happen.
    function _isSafeMode(string memory mode) internal pure returns (bool) {
        return _eq(mode, "safe");
    }

    /// @notice Whether `MODE` selects the default EOA executor. Paired with `_isSafeMode` so both
    ///         spellings are compared in one place; written out at the call site, a typo turns
    ///         `MODE=eoa` into the unknown-mode revert.
    function _isEoaMode(string memory mode) internal pure returns (bool) {
        return _eq(mode, "eoa");
    }

    /// @notice Whether `SAFE_EXEC` selects the direct-submit path rather than emitting a batch for the
    ///         owners to sign. One parse, because two callers act on it: `_run` decides what to DO and
    ///         the outcome reporting decides what to SAY. Read separately they can drift into a run
    ///         that submits a transaction while announcing a batch.
    function _execsDirect() internal view returns (bool) {
        return _isDirect(VM.envOr(SAFE_EXEC_ENV, string("")));
    }

    /// @notice The `SAFE_EXEC` vocabulary over an explicit value. Split from the env read so a test can
    ///         pin the comparison without `vm.setEnv`, which is process-wide and races the suites forge
    ///         runs in parallel. Asserting the two callers against each other would be vacuous - they
    ///         share this function, so a mutation moves both sides together.
    function _isDirect(string memory execMode) internal pure returns (bool) {
        return _eq(execMode, "direct");
    }

    /// @notice Logs every call for review and writes the Safe Transaction Builder JSON batch.
    /// @return path the batch JSON file written under `batches/`.
    function _emitBatch(string memory batchName, address safe, CctActions.Call[] memory calls)
        internal
        returns (string memory path)
    {
        console.log("");
        console.log(string.concat("  Safe mode: batching ", VM.toString(calls.length), " call(s) for Safe"));
        console.log(string.concat("  Safe:      ", VM.toString(safe)));
        for (uint256 i = 0; i < calls.length; i++) {
            console.log(
                string.concat(
                    "  Call ",
                    VM.toString(i + 1),
                    "/",
                    VM.toString(calls.length),
                    ": target ",
                    VM.toString(calls[i].target),
                    " selector ",
                    VM.toString(abi.encodePacked(bytes4(calls[i].data)))
                )
            );
            console.log(string.concat("    data: ", VM.toString(calls[i].data)));
        }

        path = string.concat("batches/", batchName, ".", VM.toString(block.chainid), ".json");
        VM.createDir("batches", true);
        SafeBatchEmitter._write(
            path, block.chainid, safe, batchName, "CCT action-layer batch (docs-cct-foundry)", calls
        );
        console.log(string.concat("  Safe batch written: ", path));
        console.log("  REVIEW the batch (decode to/value/data) BEFORE signing or importing it.");
    }

    /// @notice Collapse a `Call[]` into the single (to, value, data, operation) a Safe transaction
    ///         carries: one call passes through as a CALL; multiple calls become ONE atomic
    ///         DELEGATECALL into the canonical `MultiSendCallOnly`, which replays each inner CALL from
    ///         the Safe. Inner `to`/`value`/`data` reach the chain byte-identical to the EOA mode.
    function _encodeForSafe(CctActions.Call[] memory calls)
        internal
        pure
        returns (address to, uint256 value, bytes memory data, uint8 operation)
    {
        require(calls.length > 0, "SafeMode: empty call batch");
        if (calls.length == 1) {
            return (calls[0].target, calls[0].value, calls[0].data, 0);
        }
        bytes memory packed;
        for (uint256 i = 0; i < calls.length; i++) {
            // MultiSend packed encoding: operation (1 byte, 0=CALL) || to (20) || value (32) ||
            // dataLength (32) || data.
            packed = abi.encodePacked(
                packed, uint8(0), calls[i].target, calls[i].value, calls[i].data.length, calls[i].data
            );
        }
        return (SafeCanonical.MULTI_SEND_CALL_ONLY, 0, abi.encodeCall(IMultiSendCallOnly.multiSend, (packed)), 1);
    }

    /// @notice The direct `execTransaction` path (Mode B): compute the `safeTxHash`, cross-check the
    ///         local EIP-712 recompute against the Safe's on-chain `getTransactionHash`, sign with the
    ///         `SAFE_SIGNER_KEYS` owner keys, pack the signatures sorted ascending by signer address,
    ///         and submit from the script broadcaster. Works on every EVM chain - no Transaction
    ///         Service needed.
    function _execDirect(ISafe safe, CctActions.Call[] memory calls) internal {
        (address to, uint256 value, bytes memory data, uint8 operation) = _encodeForSafe(calls);
        uint256 nonce = safe.nonce();

        bytes32 localHash = SafeTxHash._compute(
            block.chainid,
            address(safe),
            SafeTxHash.SafeTx({
                to: to,
                value: value,
                data: data,
                operation: operation,
                safeTxGas: 0,
                baseGas: 0,
                gasPrice: 0,
                gasToken: address(0),
                refundReceiver: address(0),
                nonce: nonce
            })
        );
        bytes32 onchainHash =
            safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), address(0), nonce);
        require(localHash == onchainHash, "SafeMode: local safeTxHash recompute != Safe.getTransactionHash");

        console.log(string.concat("  safeTxHash: ", VM.toString(localHash), " (local recompute == on-chain)"));
        console.log(string.concat("  Safe nonce: ", VM.toString(nonce)));

        bytes memory signatures = _signSorted(safe, localHash);

        VM.startBroadcast();
        bool success =
            safe.execTransaction(to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures);
        VM.stopBroadcast();
        // With safeTxGas == 0 and gasPrice == 0 the Safe reverts (GS013) when the inner call fails, so
        // reaching a `true` return means the Safe emitted ExecutionSuccess.
        require(success, "SafeMode: execTransaction returned false");
        // The `success` above is the SIMULATION's return value: forge dispatches after the body
        // returns, so no ExecutionSuccess event exists yet to claim.
        OutcomeLog._sending("execute the batch on the Safe");
    }

    /// @dev Signs `hash` with every key in `SAFE_SIGNER_KEYS`, validates each signer is a Safe owner and
    ///      the count meets the threshold, and concatenates the (r,s,v) signatures sorted ascending by
    ///      signer address - the order `checkSignatures` requires. Keys are never logged.
    function _signSorted(ISafe safe, bytes32 hash) private view returns (bytes memory signatures) {
        uint256[] memory keys = VM.envUint("SAFE_SIGNER_KEYS", ",");
        require(
            keys.length >= safe.getThreshold(), "SafeMode: SAFE_SIGNER_KEYS supplies fewer keys than the Safe threshold"
        );

        // Insertion-sort the keys by their signer address (ascending).
        for (uint256 i = 1; i < keys.length; i++) {
            uint256 key = keys[i];
            uint256 j = i;
            while (j > 0 && VM.addr(keys[j - 1]) > VM.addr(key)) {
                keys[j] = keys[j - 1];
                j--;
            }
            keys[j] = key;
        }

        for (uint256 i = 0; i < keys.length; i++) {
            address signer = VM.addr(keys[i]);
            require(
                safe.isOwner(signer),
                string.concat("SafeMode: signer ", VM.toString(signer), " is not an owner of the Safe")
            );
            (uint8 v, bytes32 r, bytes32 s) = VM.sign(keys[i], hash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
