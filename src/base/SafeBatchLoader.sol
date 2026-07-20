// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {CctActions} from "../actions/CctActions.sol";

/// @title SafeBatchLoader
/// @notice Loads a Safe Transaction Builder JSON batch (the artifact `SafeBatchEmitter` writes and
///         the Safe{Wallet} UI imports) back into the action layer's `Call[]` - the exact inverse of
///         `SafeBatchEmitter._write`. This is what lets independently emitted per-operation batches be
///         COMPOSED: load each file, `CctActions._concat` them, and hand the merged `Call[]` to the
///         Safe executor as ONE atomic transaction (`test/governance/ExecuteBatch.t.sol` pins the
///         round-trip byte for byte).
library SafeBatchLoader {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Parse a Transaction Builder JSON file into its chain id, Safe address, and calls.
    function _load(string memory path)
        internal
        view
        returns (uint256 chainId, address safe, CctActions.Call[] memory calls)
    {
        string memory json = VM.readFile(path);
        // The Safe schema stringifies chainId; `createdAt`/`meta` fields other than the Safe are
        // display-only and deliberately ignored here.
        chainId = VM.parseUint(VM.parseJsonString(json, ".chainId"));
        safe = VM.parseJsonAddress(json, ".meta.createdFromSafeAddress");

        uint256 count = _transactionCount(json);
        calls = new CctActions.Call[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory prefix = string.concat(".transactions[", VM.toString(i), "]");
            calls[i] = CctActions.Call({
                target: VM.parseJsonAddress(json, string.concat(prefix, ".to")),
                value: VM.parseUint(VM.parseJsonString(json, string.concat(prefix, ".value"))),
                data: VM.parseJsonBytes(json, string.concat(prefix, ".data"))
            });
        }
    }

    /// @notice `load` plus the composition guards: the batch must be non-empty and must have been
    ///         emitted for THIS chain and THIS Safe - mixing batches across chains or Safes is the
    ///         classic composition footgun, so a mismatch reverts naming the file.
    function _loadAndValidate(string memory path, uint256 expectedChainId, address expectedSafe)
        internal
        view
        returns (CctActions.Call[] memory calls)
    {
        (uint256 chainId, address safe, CctActions.Call[] memory loaded) = _load(path);
        require(
            chainId == expectedChainId,
            string.concat(
                "SafeBatchLoader: ",
                path,
                " was emitted for chainId ",
                VM.toString(chainId),
                ", not the current chain ",
                VM.toString(expectedChainId)
            )
        );
        require(
            safe == expectedSafe,
            string.concat(
                "SafeBatchLoader: ",
                path,
                " was emitted for Safe ",
                VM.toString(safe),
                ", not SAFE_ADDRESS ",
                VM.toString(expectedSafe)
            )
        );
        require(loaded.length > 0, string.concat("SafeBatchLoader: ", path, " contains no transactions"));
        return loaded;
    }

    /// @notice Loads and validates several batch files and concatenates their calls IN THE GIVEN
    ///         ORDER - the composition primitive `ExecuteBatch` builds on. Order is execution order.
    function _loadMany(string[] memory paths, uint256 expectedChainId, address expectedSafe)
        internal
        view
        returns (CctActions.Call[] memory merged)
    {
        require(paths.length > 0, "SafeBatchLoader: no batch files given");
        for (uint256 i = 0; i < paths.length; i++) {
            CctActions.Call[] memory calls = _loadAndValidate(paths[i], expectedChainId, expectedSafe);
            merged = i == 0 ? calls : CctActions._concat(merged, calls);
        }
    }

    /// @dev Array length by index probing, the same pattern the JSON-mode scripts use (forge-std has
    ///      no direct array-length helper).
    function _transactionCount(string memory json) private view returns (uint256 count) {
        while (VM.keyExistsJson(json, string.concat(".transactions[", VM.toString(count), "]"))) {
            count++;
        }
    }
}
