// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/**
 * @title IsAllowListed
 * @notice Script to check if an address is allowlisted in an AdvancedPoolHooks contract
 *
 * Usage:
 *   POOL_HOOKS=0x... CHECK_ADDRESS=0x... forge script script/configure/allowlist/IsAllowListed.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 */
contract IsAllowListed is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > registry active.poolHooks (no manual export needed).
        address hooksAddress = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));
        require(
            hooksAddress != address(0),
            "Pool hooks not deployed. Set POOL_HOOKS or the {CHAIN}_POOL_HOOKS environment variable."
        );
        address checkAddress = vm.envAddress("CHECK_ADDRESS");

        console.log("");
        console.log("========================================");
        console.log(unicode"🔎 Is AllowListed?");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Check Address:", " ", vm.toString(checkAddress)));
        console.log(string.concat("Action:       ", "Check allowlist"));
        console.log("========================================");
        console.log("");

        // Enforcement decides what a membership check can mean. `checkAllowList` is a no-op while the
        // allowlist is disabled: it returns without reverting for every address, 0x0 included, so a
        // non-revert says nothing until enforcement is established. Enforcement is fixed at deployment
        // (`i_allowlistEnabled = allowlist.length > 0`, immutable), so hooks deployed with an empty
        // allowlist can never enforce one.
        bool enforced;
        try AdvancedPoolHooks(hooksAddress).getAllowListEnabled() returns (bool enabled) {
            enforced = enabled;
        } catch {
            console.log(unicode"❓ Could not read the allowlist state at this address.");
            console.log("   Without it, nothing can be reported about CHECK_ADDRESS.");
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
            console.log(
                unicode"⚠️  These hooks enforce NO allowlist: every sender is permitted, this one included."
            );
            console.log("   Enforcement is fixed at deployment and cannot be turned on later. To restrict");
            console.log("   senders, deploy AdvancedPoolHooks with a non-empty ALLOWLIST and point the");
            console.log("   pool at it.");
            console.log("========================================");
            console.log(
                string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress))
            );
            console.log("========================================");
            console.log("");
            return;
        }

        // Enforcement is on, so a revert now carries the membership answer and nothing else.
        bool isAllowListed = false;
        try AdvancedPoolHooks(hooksAddress).checkAllowList(checkAddress) {
            isAllowListed = true;
        } catch {}

        if (isAllowListed) {
            console.log(unicode"✅ Address IS allowlisted.");
        } else {
            console.log(unicode"❌ Address is NOT allowlisted.");
        }
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }
}
