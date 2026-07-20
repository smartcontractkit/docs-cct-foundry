// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";

library HelperUtils {
    using stdJson for string;

    function _getAddressFromJson(Vm vm, string memory path, string memory key) internal view returns (address) {
        string memory json = vm.readFile(path);
        return json.readAddress(key);
    }

    function _getBoolFromJson(Vm vm, string memory path, string memory key) internal view returns (bool) {
        string memory json = vm.readFile(path);
        return json.readBool(key);
    }

    function _getStringFromJson(Vm vm, string memory path, string memory key) internal view returns (string memory) {
        string memory json = vm.readFile(path);
        return json.readString(key);
    }

    function _getUintFromJson(Vm vm, string memory path, string memory key) internal view returns (uint256) {
        string memory json = vm.readFile(path);
        return json.readUint(key);
    }

    /**
     * @notice Parses an address array from a JSON file or an inline string.
     * @dev If `key` is non-empty, reads the JSON file at `pathOrInput` and ABI-decodes the array at `key`.
     *      If `key` is empty, treats `pathOrInput` as an inline value:
     *        - Starts with '[' → parsed as a JSON array string.
     *        - Otherwise       → parsed as a comma-separated list of hex addresses.
     *
     *      Examples:
     *        parseAddressArray(vm, "/path/to/config.json", ".allowlist")  // from file
     *        parseAddressArray(vm, '["0xAbc...","0xDef..."]', "")         // inline JSON
     *        parseAddressArray(vm, "0xAbc...,0xDef...", "")               // inline CSV
     */
    function _parseAddressArray(Vm vm, string memory pathOrInput, string memory key)
        internal
        view
        returns (address[] memory)
    {
        if (bytes(pathOrInput).length == 0) return new address[](0);

        if (bytes(key).length > 0) {
            // File + key branch
            string memory json = vm.readFile(pathOrInput);
            return vm.parseJsonAddressArray(json, key);
        }

        // Inline branch
        bytes memory b = bytes(pathOrInput);
        if (b[0] == "[") {
            // Inline JSON array - key "." selects the root array
            return vm.parseJsonAddressArray(pathOrInput, ".");
        }

        // Inline CSV
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }
        address[] memory arr = new address[](count);
        uint256 start = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = 0; j < i - start; j++) {
                    slice[j] = b[start + j];
                }
                arr[idx++] = vm.parseAddress(string(slice));
                start = i + 1;
            }
        }
        return arr;
    }
}
