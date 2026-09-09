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

        // forge-lint: disable-next-line(uninitialized-local) - the catch reverts rather than reporting an unread allowlist state
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

        // Enforcement is on, so a SenderNotAllowed revert carries the membership answer. Nothing else
        // does: a bare `catch {}` here would turn an out-of-gas, an RPC failure, or a proxy reverting
        // for its own reasons into a confident "NOT allowlisted", which is a definite verdict derived
        // from a read that never happened. Match the selector, and refuse anything else - the same
        // rule the getAllowListEnabled() catch above applies by reverting.
        bool isAllowListed = false;
        try AdvancedPoolHooks(hooksAddress).checkAllowList(checkAddress) {
            isAllowListed = true;
        } catch (bytes memory reason) {
            if (bytes4(reason) != AdvancedPoolHooks.SenderNotAllowed.selector) {
                console.log(string.concat("checkAllowList(", vm.toString(checkAddress), ") reverted unexpectedly."));
                console.logBytes(reason);
                revert("checkAllowList() did not answer - membership is UNKNOWN, not negative");
            }
        }

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
