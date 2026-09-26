// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/**
 * @title GetPolicyEngine
 * @notice Script to read the ACE Policy Engine address currently set on an AdvancedPoolHooks contract
 *
 * Usage:
 *   POOL_HOOKS=0x... forge script script/configure/policy-engine/GetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
 */
contract GetPolicyEngine is Script {
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
        console.log(unicode"🔎 Get Policy Engine");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Action:       ", "View policy engine"));
        console.log("========================================");
        console.log("");

        address policyEngine = AdvancedPoolHooks(hooksAddress).getPolicyEngine();
        if (policyEngine == address(0)) {
            console.log("No policy engine is set on these hooks.");
            console.log("   Policy checks are disabled: preflightCheck/postflightCheck skip the engine.");
            console.log("   Set one with SetPolicyEngine.s.sol (POLICY_ENGINE=<address>).");
        } else {
            console.log(unicode"✅ Policy Engine:");
            console.log(string.concat("   ", vm.toString(policyEngine)));
        }

        console.log("");
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }
}
