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
