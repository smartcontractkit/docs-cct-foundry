// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {SafeBatchLoader} from "../../src/base/SafeBatchLoader.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

/// @notice Composes several independently emitted Safe batches into ONE Safe meta-transaction.
///
/// Workflow: run each write script with `MODE=safe` (emit-only) and a distinct `BATCH_NAME` - each
/// run performs its own preflight and writes `batches/<name>.<chainId>.json`. Then run this script
/// with the files to compose, in execution order. It loads every file back into the action layer's
/// `Call[]` (validating each was emitted for THIS chain and THIS Safe), concatenates them, and hands
/// the merged batch to the standard Safe executor: ONE merged Transaction Builder JSON is emitted
/// for review (importable in the Safe{Wallet} UI, proposable via `safe-cli`, unchanged), and with
/// `SAFE_EXEC=direct` it executes as ONE atomic `execTransaction` (a single MultiSendCallOnly batch:
/// one safeTxHash, one signing ceremony, one Safe nonce; a failing call reverts the whole batch).
///
/// Safe mode only, by design: an EOA has no execution context to batch atomically, so this script
/// does not participate in the `MODE` switch.
///
/// Environment Variables:
///   SAFE_ADDRESS      (required) the Safe executing the batch; every input file must match it
///   BATCH_NAME        (required, no default) name of the MERGED batch artifact - explicit so a
///                     composition can never silently clobber another batch file
///   BATCH_FILES       (required) comma-separated batch JSON paths, in EXECUTION ORDER
///   SAFE_EXEC         (optional) unset = emit the merged batch only; `direct` = execute now
///   SAFE_SIGNER_KEYS  (required for SAFE_EXEC=direct) comma-separated owner keys, never logged
///
/// Example:
///   SAFE_ADDRESS=$SAFE BATCH_NAME=full-setup \
///   BATCH_FILES=batches/claim.11155111.json,batches/set-pool.11155111.json \
///   forge script script/governance/ExecuteBatch.s.sol --rpc-url $RPC
contract ExecuteBatch is Script {
    function run() external returns (string memory mergedBatchPath) {
        address safe = vm.envAddress("SAFE_ADDRESS");
        // Read BATCH_NAME without a default: composing under the executor's fallback name is the
        // silent-clobber footgun this script exists to avoid.
        string memory batchName = vm.envString("BATCH_NAME");
        require(bytes(batchName).length > 0, "BATCH_NAME must be set to name the merged batch");
        string[] memory files = vm.envString("BATCH_FILES", ",");
        require(files.length > 0, "BATCH_FILES must list at least one batch JSON");

        console.log("");
        console.log("========================================");
        console.log(unicode"🧩 Compose Safe batches into one transaction");
        console.log("========================================");
        console.log(string.concat("Safe:         ", vm.toString(safe)));
        console.log(string.concat("Merged batch: ", batchName));
        console.log(string.concat("Input files:  ", vm.toString(files.length)));

        for (uint256 i = 0; i < files.length; i++) {
            console.log(string.concat("  [", vm.toString(i + 1), "] ", files[i]));
        }
        CctActions.Call[] memory merged = SafeBatchLoader._loadMany(files, block.chainid, safe);
        console.log(string.concat("Total calls:  ", vm.toString(merged.length)));
        console.log("========================================");

        // The standard Safe executor takes over: full per-call review logging, ONE merged canonical
        // batch JSON, and (SAFE_EXEC=direct) ONE atomic execTransaction.
        mergedBatchPath = SafeMode._run(merged);
    }
}
