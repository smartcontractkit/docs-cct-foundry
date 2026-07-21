// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/**
 * @title UpdateAdvancedPoolHooks
 * @notice Script to update the AdvancedPoolHooks address for a deployed TokenPool
 * @dev Calls TokenPool.updateAdvancedPoolHooks(newHook) as owner
 *
 * Usage:
 *   TOKEN_POOL=0x... NEW_HOOK=0x... forge script script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract UpdateAdvancedPoolHooks is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = vm.envOr("TOKEN_POOL", helperConfig.getDeployedTokenPool(chainId));
        address newHookAddress = vm.envAddress("NEW_HOOK");

        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set TOKEN_POOL env var or ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🔄 Update Advanced Pool Hooks");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Update pool hooks"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("New Pool Hooks: ", vm.toString(newHookAddress)));
        console.log("");

        _executeCalls(CctActions._updateAdvancedPoolHooks(tokenPoolAddress, newHookAddress));
        console.log(unicode"✅ AdvancedPoolHooks updated successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Pool hooks updated on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:     ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("New Pool Hooks: ", vm.toString(newHookAddress)));
        console.log(
            string.concat("Token Pool:     ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log(
            string.concat("New Pool Hooks: ", helperConfig.getExplorerUrl(chainId, "/address/", newHookAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
