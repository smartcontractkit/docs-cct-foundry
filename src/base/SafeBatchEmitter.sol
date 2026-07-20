// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {CctActions} from "../actions/CctActions.sol";

/// @title SafeBatchEmitter
/// @notice Serializes an action-layer `Call[]` into the canonical Safe Transaction Builder JSON - the
///         exact shape the Safe{Wallet} UI's "Transaction Builder" app imports and `safe-cli` can
///         propose to the Safe Transaction Service. The emitted file carries the IDENTICAL `to`,
///         `value`, and `data` the EOA mode would broadcast, so reviewing the batch reviews the same
///         calldata (`test/governance/SafeMode.t.sol` pins this equality).
/// @dev The Safe UI wraps the listed `transactions` in a MultiSend on import, so the individual CALLs
///      are emitted, not the MultiSend wrapper. Values are decimal strings; data is 0x-hex. The JSON is
///      built entirely in Solidity via `vm` cheatcodes - no external tooling touches batch generation -
///      and is key-free: only addresses and calldata ever reach the artifact.
library SafeBatchEmitter {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev a single JSON double-quote
    function _q() private pure returns (string memory) {
        return "\"";
    }

    /// @dev `"key":"value"` (quoted string value)
    function _str(string memory key, string memory value) private pure returns (string memory) {
        string memory q = _q();
        return string.concat(q, key, q, ":", q, value, q);
    }

    /// @dev `"key":<raw>` (raw/unquoted value: a nested object, number, or null)
    function _raw(string memory key, string memory value) private pure returns (string memory) {
        string memory q = _q();
        return string.concat(q, key, q, ":", value);
    }

    function _transaction(CctActions.Call memory call) private pure returns (string memory) {
        string memory obj = string.concat("{", _str("to", VM.toString(call.target)));
        obj = string.concat(obj, ",", _str("value", VM.toString(call.value)));
        obj = string.concat(obj, ",", _str("data", VM.toString(call.data)));
        obj = string.concat(obj, ",", _raw("contractMethod", "null"));
        obj = string.concat(obj, ",", _raw("contractInputsValues", "null"), "}");
        return obj;
    }

    /// @notice Write the Safe Transaction Builder JSON for `calls` to `path`.
    /// @param path        output file (must be under a `fs_permissions` read-write path)
    /// @param chainId     target chain id (stringified in the JSON, per the Safe schema)
    /// @param safe        the Safe that will execute the batch (`createdFromSafeAddress`)
    /// @param name        batch name (`meta.name`)
    /// @param description batch description (`meta.description`)
    /// @param calls       the individual CALLs the Safe should perform, unchanged from the action layer
    function _write(
        string memory path,
        uint256 chainId,
        address safe,
        string memory name,
        string memory description,
        CctActions.Call[] memory calls
    ) internal {
        string memory txs = "[";
        for (uint256 i = 0; i < calls.length; i++) {
            txs = string.concat(txs, i == 0 ? "" : ",", _transaction(calls[i]));
        }
        txs = string.concat(txs, "]");

        string memory meta = string.concat("{", _str("name", name));
        meta = string.concat(meta, ",", _str("description", description));
        meta = string.concat(meta, ",", _str("txBuilderVersion", "1.17.1"));
        meta = string.concat(meta, ",", _str("createdFromSafeAddress", VM.toString(safe)));
        meta = string.concat(meta, ",", _str("createdFromOwnerAddress", ""), "}");

        string memory json = string.concat("{", _str("version", "1.0"));
        json = string.concat(json, ",", _str("chainId", VM.toString(chainId)));
        json = string.concat(json, ",", _raw("createdAt", "0"));
        json = string.concat(json, ",", _raw("meta", meta));
        json = string.concat(json, ",", _raw("transactions", txs), "}");

        VM.writeFile(path, json);
    }
}
