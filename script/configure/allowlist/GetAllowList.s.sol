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

        address[] memory allowList = AdvancedPoolHooks(hooksAddress).getAllowList();
        console.log(string.concat("AllowList count: ", vm.toString(allowList.length)));
        for (uint256 i = 0; i < allowList.length; i++) {
            console.log(string.concat("  ", vm.toString(allowList[i])));
        }
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }
}
