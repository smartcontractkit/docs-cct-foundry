// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title RolesCheck
/// @notice **`make roles-check CHAIN=<name>` - READ-ONLY reconcile of the declared `roles{}` against
/// the live chain.** It never writes a file and never broadcasts; the only outputs are the aligned
/// [PASS]/[FAIL]/[WARN]/[SKIP] lines from `RolesAuditor` and the exit status. The CI-ready exit-code
/// contract (0 clean / 1 roles-drift / 2 rpc-unavailable) belongs to the wrapper
/// `script/config/roles-check.sh`, which classifies this script's output - GNU make remaps any
/// failing recipe to its own exit 2, so `make roles-check` is pass/fail only; CI calls the script
/// directly (the same lesson as `sync-check.sh`).
/// @dev Sentinels this script prints for the wrapper to classify:
///   - `NO_ROLES_DECLARED` - the chain has no `roles{}` block (SKIP; bootstrap with snapshot-chain)
///   - `RPC_UNAVAILABLE`   - the chain's rpcEnv is unset or the fork failed (flake, not drift)
///   - `ROLES_DRIFT`       - at least one declared field mismatches the live chain
contract RolesCheck is Script {
    function run(string memory name) public {
        // Chain FACTS come from config/chains (pure API); the DECLARED roles{} comes from the project store.
        string memory configPath = string.concat("config/chains/", name, ".json");
        require(vm.exists(configPath), string.concat("unknown chain '", name, "' - no ", configPath));
        string memory configJson = vm.readFile(configPath);
        require(
            keccak256(bytes(vm.parseJsonString(configJson, ".chainFamily"))) == keccak256(bytes("evm")),
            string.concat("[roles-check] ", name, " is not an EVM chain - roles{} reconcile covers EVM only")
        );

        ProjectStore._requireSchema(name); // named error on a wrong-schema/corrupt project file
        string memory projectPath = ProjectStore._path(name);
        if (!vm.exists(projectPath) || !vm.keyExistsJson(vm.readFile(projectPath), ".roles.token")) {
            string memory grp = ProjectStore._group();
            console.log(
                string.concat(
                    "[roles-check] NO_ROLES_DECLARED for ",
                    name,
                    " - bootstrap with: make snapshot-chain CHAIN=",
                    name,
                    bytes(grp).length != 0 ? string.concat(" GROUP=", grp) : ""
                )
            );
            return;
        }
        string memory projectJson = vm.readFile(projectPath);
        string memory rpcEnv = vm.parseJsonString(configJson, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        require(
            bytes(url).length != 0,
            string.concat("[roles-check] RPC_UNAVAILABLE: env ", rpcEnv, " unset - add it to .env")
        );
        try vm.createSelectFork(url) {}
        catch {
            revert(string.concat("[roles-check] RPC_UNAVAILABLE: could not fork via ", rpcEnv));
        }
        require(
            block.chainid == vm.parseJsonUint(configJson, ".chainId"),
            string.concat("[roles-check] RPC ", rpcEnv, " points at the wrong chainId for ", name)
        );

        RolesAuditor.Result memory r = (new RolesAuditor()).auditJson(name, projectJson);
        if (r.fails != 0) {
            revert(
                string.concat(
                    "[roles-check] ROLES_DRIFT for ",
                    name,
                    ": ",
                    vm.toString(r.fails),
                    " field(s) mismatch (",
                    r.failedFields,
                    ") - remediate on-chain or re-declare via: make snapshot-chain CHAIN=",
                    name
                )
            );
        }
        console.log(string.concat("[roles-check] CLEAN for ", name, " - declared authority matches the live chain"));
    }
}
