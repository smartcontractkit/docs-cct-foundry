// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/**
 * @title SetPolicyEngine
 * @notice Script to point an AdvancedPoolHooks contract at an ACE Policy Engine on the same chain,
 *         or disconnect the engine with the zero address.
 * @dev Calls setPolicyEngine(newPolicyEngine) as the hooks owner. The hook calls attach() on the new
 *      engine, which starts ACE target detection. When an old engine is set, setPolicyEngine calls
 *      detach() on it first and reverts PolicyEngineDetachReverted if that call reverts; the on-chain
 *      recovery path for that case is setPolicyEngineAllowFailedDetach on the hook itself.
 *
 * Usage:
 *   POOL_HOOKS=0x... POLICY_ENGINE=0x... forge script script/configure/policy-engine/SetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   POOL_HOOKS=0x... POLICY_ENGINE=0x0000000000000000000000000000000000000000 forge script script/configure/policy-engine/SetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   POOL_HOOKS     - address of the AdvancedPoolHooks contract (alias > {CHAIN}_POOL_HOOKS > registry)
 *   POLICY_ENGINE  - address of the ACE Policy Engine on the same chain, or the zero address to disconnect
 */
contract SetPolicyEngine is EoaExecutor {
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

        address newPolicyEngine = vm.envAddress("POLICY_ENGINE");

        // Read the current engine before the write so the report can name what is being replaced.
        // A same-address update is a no-op on the hook, so refuse it before broadcasting: the run
        // would report success and link a real transaction that changed nothing.
        address currentEngine = AdvancedPoolHooks(hooksAddress).getPolicyEngine();
        require(
            newPolicyEngine != currentEngine,
            string.concat(
                "POLICY_ENGINE equals the current engine (",
                vm.toString(currentEngine),
                "). setPolicyEngine would be a no-op. Pass a different address."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Set Policy Engine");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Action:       ", "Set policy engine"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Current Policy Engine: ", vm.toString(currentEngine)));
        console.log(string.concat("New Policy Engine:     ", vm.toString(newPolicyEngine)));
        if (newPolicyEngine == address(0)) {
            console.log("   The zero address disconnects the engine and stops policy checks.");
        }
        console.log("");

        _executeCalls(CctActions._setPolicyEngine(hooksAddress, newPolicyEngine));

        _logOperationOutcome(string.concat("point the pool hooks at policy engine ", vm.toString(newPolicyEngine)));
        console.log("");
        console.log("========================================");
        _logOperationOutcome(string.concat("set the policy engine on ", chainName));
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }
}
