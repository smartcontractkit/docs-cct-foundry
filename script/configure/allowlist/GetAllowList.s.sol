// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/**
 * @title GetAllowList
 * @notice Script to fetch and print the allowlist from an AdvancedPoolHooks contract
 *
 * Usage:
 *   POOL_HOOKS=0x... forge script script/configure/allowlist/GetAllowList.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 */
contract GetAllowList is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > registry active.poolHooks (no manual export needed).
        address hooksAddress = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));
        require(
            hooksAddress != address(0),
            string.concat(
                "AdvancedPoolHooks not deployed. Set POOL_HOOKS env var or ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_POOL_HOOKS."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🔎 Get AllowList");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Action:       ", "View allowlist"));
        console.log("========================================");
        console.log("");

        // The list alone is ambiguous: an empty one means every sender is permitted when the hooks were
        // deployed without an allowlist, and nobody may send when they were deployed with one and it was
        // since emptied. Print the enforcement state so the list can be read.
        bool enforced;
        try AdvancedPoolHooks(hooksAddress).getAllowListEnabled() returns (bool enabled) {
            enforced = enabled;
        } catch {
            console.log(unicode"❓ Could not read the allowlist state at this address.");
            console.log("   Without it, an allowlist read here cannot be interpreted.");
            console.log(
                string.concat("   Confirm POOL_HOOKS is an AdvancedPoolHooks contract: ", vm.toString(hooksAddress))
            );
            console.log("========================================");
            console.log("");
            // The revert carries the failure into the exit code: printing an error and exiting 0
            // would tell any wrapper reading it that the allowlist state was read.
            revert("getAllowListEnabled() could not be read (see above)");
        }
        if (!enforced) {
            console.log(unicode"⚠️  These hooks enforce NO allowlist: every sender is permitted.");
            console.log("   Enforcement is fixed at deployment and cannot be turned on later. To restrict");
            console.log("   senders, deploy AdvancedPoolHooks with a non-empty ALLOWLIST and point the");
            console.log("   pool at it.");
        } else {
            // Name the enforcement state rather than leave it implied by the absence of the warning
            // above: with it, a count of zero reads as what it is.
            address[] memory allowList = AdvancedPoolHooks(hooksAddress).getAllowList();
            console.log("Allowlist enforcement: ON");
            console.log(string.concat("AllowList count: ", vm.toString(allowList.length)));
            if (allowList.length == 0) {
                console.log(unicode"⚠️  The list is enforced and empty: NO sender is permitted.");
            }
            for (uint256 i = 0; i < allowList.length; i++) {
                console.log(string.concat("  ", vm.toString(allowList[i])));
            }
        }
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }
}
