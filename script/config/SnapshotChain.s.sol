// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title SnapshotChain
/// @notice **`make snapshot-chain CHAIN=<name>` — backfill the DECLARED authority state FROM chain.**
/// Reads the live role surface (owner/defaultAdmin/getCCIPAdmin/hasRole/TAR getTokenConfig/
/// dual-generation pool admins/getAllAuthorizedCallers/getAllowList/...) through `RolesSnapshot` and
/// writes the `roles{}` subtree of `project/<selectorName>.json` (preserve-and-replace, the same
/// single-subtree pattern as the `ccip{}` sync). Chain FACTS (`chainFamily`, `rpcEnv`, `chainId`, the
/// directory `.ccip.tokenAdminRegistry`) are read from `config/chains/<name>.json`; the authority state
/// is written to the project store. Reconcile forever after with `make roles-check CHAIN=<name>` — this
/// script is the ONLY writer of `roles{}`.
/// @dev Writer rule (docs/config-schema.md): `roles{}` is written by THIS tool — NEVER by the API
/// sync (roles are project authority, not directory data). First touch seeds the project skeleton
/// (all three subtrees), so a chain with no `project/<name>.json` yet never raw-reverts. Optional env:
///   - `TOKEN=<addr>` / `TOKEN_POOL=<addr>`  the project addresses when the chain has no declared
///     `roles{}` anchor yet and no `project/<name>.json` active pointers (or to snapshot a
///     second token on a multi-token chain).
///   - `TAR=<addr>`            the TAR the token is REGISTERED in when it differs from
///     `.ccip.tokenAdminRegistry`.
///   - `SCAN_FROM_BLOCK=<n>`   enable the RoleGranted/RoleRevoked event scan so non-enumerable
///     role-holder lists can be marked `"complete": true`.
contract SnapshotChain is Script {
    function run(string memory name) public {
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("sync")),
            "run via make snapshot-chain CHAIN=<name> (FOUNDRY_PROFILE=sync enables the store write)"
        );
        string memory configPath = string.concat("config/chains/", name, ".json");
        require(
            vm.exists(configPath),
            string.concat("[snapshot] no ", configPath, " - new chain? make add-chain CHAIN=", name, " SELECTOR=<sel>")
        );
        string memory configJson = vm.readFile(configPath);
        require(
            keccak256(bytes(vm.parseJsonString(configJson, ".chainFamily"))) == keccak256(bytes("evm")),
            string.concat("[snapshot] ", name, " is not an EVM chain - the roles{} snapshot covers EVM only")
        );
        string memory rpcEnv = vm.parseJsonString(configJson, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        require(
            bytes(url).length != 0, string.concat("[snapshot] RPC_UNAVAILABLE: env ", rpcEnv, " unset - add it to .env")
        );
        vm.createSelectFork(url);
        require(
            block.chainid == vm.parseJsonUint(configJson, ".chainId"),
            string.concat("[snapshot] RPC ", rpcEnv, " points at the wrong chainId for ", name)
        );

        // Seed the project skeleton (all three subtrees) if this is the chain's first touch, so the
        // targeted `.roles` write below never hits a cannot-create-key revert.
        ProjectStore.seedIfAbsent(name);
        string memory projectPath = ProjectStore.path(name);
        string memory projectJson = vm.readFile(projectPath);

        string memory rolesJson = (new RolesSnapshot()).build(name, configJson, projectJson);
        vm.writeJson(rolesJson, projectPath, ".roles");
        console.log(string.concat("[snapshot] wrote .roles block for ", name, " -> ", ProjectStore.display(name)));
        string memory grp = ProjectStore.group();
        console.log(
            string.concat(
                "[snapshot] reconcile any time with: make roles-check CHAIN=",
                name,
                bytes(grp).length != 0 ? string.concat(" GROUP=", grp) : ""
            )
        );
    }
}
