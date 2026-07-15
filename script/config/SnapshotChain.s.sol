// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";

/// @title SnapshotChain
/// @notice **`make snapshot-chain CHAIN=<name>` — backfill the DECLARED authority state FROM chain.**
/// Reads the live role surface (owner/defaultAdmin/getCCIPAdmin/hasRole/TAR getTokenConfig/
/// dual-generation pool admins/getAllAuthorizedCallers/getAllowList/...) through `RolesSnapshot` and
/// writes the `roles{}` subtree of `config/chains/<name>.json` (preserve-and-replace, the same
/// single-subtree pattern as the `ccip{}` sync). Reconcile forever after with
/// `make roles-check CHAIN=<name>` — this script is the ONLY writer of `roles{}`.
/// @dev Writer rule (docs/config-schema.md): `roles{}` is written by THIS tool — NEVER by the API
/// sync (roles are project authority, not directory data). Optional env:
///   - `TOKEN=<addr>` / `TOKEN_POOL=<addr>`  the project addresses when the chain has no declared
///     `roles{}` anchor yet and no `addresses/<chainId>.json` active pointers (or to snapshot a
///     second token on a multi-token chain).
///   - `TAR=<addr>`            the TAR the token is REGISTERED in when it differs from
///     `.ccip.tokenAdminRegistry`.
///   - `SCAN_FROM_BLOCK=<n>`   enable the RoleGranted/RoleRevoked event scan so non-enumerable
///     role-holder lists can be marked `"complete": true`.
contract SnapshotChain is Script {
    function run(string memory name) public {
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("sync")),
            "run via make snapshot-chain CHAIN=<name> (FOUNDRY_PROFILE=sync enables the config write)"
        );
        string memory path = string.concat("config/chains/", name, ".json");
        require(
            vm.exists(path),
            string.concat("[snapshot] no ", path, " - new chain? make add-chain CHAIN=", name, " SELECTOR=<sel>")
        );
        string memory json = vm.readFile(path);
        require(
            keccak256(bytes(vm.parseJsonString(json, ".chainFamily"))) == keccak256(bytes("evm")),
            string.concat("[snapshot] ", name, " is not an EVM chain - the roles{} snapshot covers EVM only")
        );
        string memory rpcEnv = vm.parseJsonString(json, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        require(
            bytes(url).length != 0, string.concat("[snapshot] RPC_UNAVAILABLE: env ", rpcEnv, " unset - add it to .env")
        );
        vm.createSelectFork(url);
        require(
            block.chainid == vm.parseJsonUint(json, ".chainId"),
            string.concat("[snapshot] RPC ", rpcEnv, " points at the wrong chainId for ", name)
        );

        string memory rolesJson = (new RolesSnapshot()).build(name, json);
        _ensureRolesKey(path);
        vm.writeJson(rolesJson, path, ".roles");
        console.log(string.concat("[snapshot] wrote .roles block for ", name, " -> ", path));
        console.log(string.concat("[snapshot] reconcile any time with: make roles-check CHAIN=", name));
    }

    /// @dev `vm.writeJson(json, path, ".roles")` cannot CREATE the key — ensure it exists first (jq,
    /// ffi; the sync profile grants both ffi and read-write access).
    function _ensureRolesKey(string memory path) private {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-lc";
        cmd[2] = string.concat(
            "jq 'if has(\"roles\") then . else . + {\"roles\": {}} end' ",
            path,
            " > ",
            path,
            ".tmp && mv ",
            path,
            ".tmp ",
            path
        );
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        require(r.exitCode == 0, string(bytes.concat(bytes("[snapshot] ensure .roles key failed: "), r.stderr)));
    }
}
