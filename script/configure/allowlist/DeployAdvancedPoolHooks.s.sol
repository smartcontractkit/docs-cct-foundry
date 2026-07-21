// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {DeploymentUtils} from "../../utils/DeploymentUtils.s.sol";
import {DeploymentRecorder} from "../../utils/DeploymentRecorder.s.sol";
import {RegistryWriter} from "../../../src/utils/RegistryWriter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/**
 * @title DeployAdvancedPoolHooks
 * @notice Optional script to deploy AdvancedPoolHooks for enhanced token pool security
 * @dev AdvancedPoolHooks provides:
 *      - Allowlist functionality for sender restrictions
 *      - CCV (Cross-Chain Validation) configuration management
 *      - Policy engine integration for custom validation logic
 *      - Threshold-based additional security for large transfers
 *
 * Configuration is read from script/input/advanced-pool-hooks.json, which can be overridden per-field
 * using environment variables.
 *
 * Usage:
 *   forge script script/configure/allowlist/DeployAdvancedPoolHooks.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variable overrides (all optional, fall back to script/input/advanced-pool-hooks.json):
 *   ALLOWLIST           - CSV or JSON array of allowed addresses  (e.g. "0xA,0xB" or '["0xA","0xB"]')
 *   AUTHORIZED_CALLERS  - CSV or JSON array of authorized pool addresses
 *   THRESHOLD_AMOUNT    - uint256 threshold amount
 *   POLICY_ENGINE       - address of the policy engine contract
 *
 * Edit script/input/advanced-pool-hooks.json to configure defaults:
 *   - allowlist: Array of addresses allowed to transfer tokens
 *   - thresholdAmount: Amount above which additional CCVs are required
 *   - policyEngine: Address of policy engine contract (or 0x0 to disable)
 *   - authorizedCallers: Array of token pool addresses authorized to use these hooks
 */
contract DeployAdvancedPoolHooks is Script {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        string memory selectorName = helperConfig.getSelectorName(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔒 Deploy Advanced Pool Hooks");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Deploy pool hooks"));
        console.log("========================================");
        console.log("");

        // Define the path to the configuration file
        string memory configPath = string.concat(vm.projectRoot(), "/script/input/advanced-pool-hooks.json");

        // Parse parameters - env vars take priority, JSON config is the fallback
        address[] memory allowlist = bytes(vm.envOr("ALLOWLIST", string(""))).length > 0
            ? HelperUtils._parseAddressArray(vm, vm.envOr("ALLOWLIST", string("")), "")
            : HelperUtils._parseAddressArray(vm, configPath, ".allowlist");

        uint256 thresholdAmount =
            vm.envOr("THRESHOLD_AMOUNT", HelperUtils._getUintFromJson(vm, configPath, ".thresholdAmount"));
        address policyEngine =
            vm.envOr("POLICY_ENGINE", HelperUtils._getAddressFromJson(vm, configPath, ".policyEngine"));

        address[] memory authorizedCallers = bytes(vm.envOr("AUTHORIZED_CALLERS", string(""))).length > 0
            ? HelperUtils._parseAddressArray(vm, vm.envOr("AUTHORIZED_CALLERS", string("")), "")
            : HelperUtils._parseAddressArray(vm, configPath, ".authorizedCallers");

        console.log("Advanced Pool Hooks Parameters:");
        console.log(string.concat("  Allowlist Enabled:            ", allowlist.length > 0 ? "Yes" : "No"));
        if (allowlist.length > 0) {
            console.log(string.concat("  Allowlist Size:               ", vm.toString(allowlist.length)));
            for (uint256 i = 0; i < allowlist.length; i++) {
                console.log(string.concat("    [", vm.toString(i), "] ", vm.toString(allowlist[i])));
            }
        }
        console.log(
            string.concat(
                "  Threshold Amount:             ", thresholdAmount > 0 ? vm.toString(thresholdAmount) : "Disabled (0)"
            )
        );
        console.log(
            string.concat(
                "  Policy Engine:                ",
                policyEngine != address(0) ? vm.toString(policyEngine) : "Disabled (0x0)"
            )
        );
        console.log(string.concat("  Authorized Callers Enabled:   ", authorizedCallers.length > 0 ? "Yes" : "No"));
        if (authorizedCallers.length > 0) {
            console.log(string.concat("  Authorized Callers Size:      ", vm.toString(authorizedCallers.length)));
            for (uint256 i = 0; i < authorizedCallers.length; i++) {
                console.log(string.concat("    [", vm.toString(i), "] ", vm.toString(authorizedCallers[i])));
            }
        }
        console.log("");

        // Hooks belong to a token's pool, so the registry key carries the token symbol and pool type
        // (see _hooksDeploymentName). Refuse to redeploy over a live registry entry (FORCE_REDEPLOY
        // overrides). The name is composed in a helper to keep this stack-heavy function under the limit.
        RegistryWriter._guard(selectorName, _hooksDeploymentName(chainId));

        vm.startBroadcast();

        console.log(string.concat("\n[Step 1] Deploying AdvancedPoolHooks on ", chainName));
        AdvancedPoolHooks hooks = new AdvancedPoolHooks(allowlist, thresholdAmount, policyEngine, authorizedCallers);
        address hooksAddress = address(hooks);
        console.log(string.concat("AdvancedPoolHooks deployed at: ", vm.toString(hooksAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress));
        console.log(unicode"✅ AdvancedPoolHooks deployed successfully!");

        vm.stopBroadcast();

        _recordAndReport(chainId, chainName, hooksAddress, allowlist, thresholdAmount, policyEngine, authorizedCallers);
    }

    /// @dev Post-deploy: the single-writer registry+ledger record and the human-readable summary.
    /// Split off `run()` so its locals do not add to that stack-heavy function.
    function _recordAndReport(
        uint256 chainId,
        string memory chainName,
        address hooksAddress,
        address[] memory allowlist,
        uint256 thresholdAmount,
        address policyEngine,
        address[] memory authorizedCallers
    ) private {
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deployment Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("AdvancedPoolHooks Address: ", vm.toString(hooksAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress));
        console.log("");
        // Single writer: one call emits the detailed ledger file AND records the address in the
        // store (deployments[{symbol}_{poolType}_PoolHooks] + active.poolHooks).
        DeploymentRecorder._recordPoolHooks(
            vm,
            helperConfig.getSelectorName(chainId),
            hooksAddress,
            helperConfig.getDeployedToken(chainId),
            _hooksPoolType()
        );
        console.log("");
        console.log("Configuration Summary:");
        console.log(string.concat("  Allowlist:                    ", allowlist.length > 0 ? "Enabled" : "Disabled"));
        console.log(
            string.concat(
                "  Threshold:                    ", thresholdAmount > 0 ? vm.toString(thresholdAmount) : "Disabled"
            )
        );
        console.log(
            string.concat(
                "  Policy Engine:                ", policyEngine != address(0) ? vm.toString(policyEngine) : "Disabled"
            )
        );
        console.log(
            string.concat("  Authorized Callers:           ", authorizedCallers.length > 0 ? "Enabled" : "Disabled")
        );
        console.log("");
        console.log("Next Steps:");
        console.log("  1. When deploying a TokenPool, pass this hooks address as the 'poolHooks' parameter");
        console.log(
            "  2. Attach to an existing pool: TOKEN_POOL=<address> NEW_HOOK=<address> forge script script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol --rpc-url $RPC_URL --account $KEYSTORE_NAME --broadcast"
        );
        console.log(
            "  3. Manage allowlist: POOL_HOOKS=<address> ADD_ADDRESSES=\"0xAddr\" forge script script/configure/allowlist/UpdateAllowList.s.sol --rpc-url $RPC_URL --account $KEYSTORE_NAME --broadcast"
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev The `deployments` key for these hooks: `{symbol}_{poolType}_PoolHooks`. The symbol comes
    /// from the chain's deployed token (env `TOKEN` / `{CHAIN}_TOKEN` / registry, else `TOKEN_SYMBOL`
    /// / "unknown"); the pool type from env `POOL_TYPE` (default "BurnMint"). Split into its own
    /// function so its locals do not add to the stack-heavy `run()`.
    function _hooksDeploymentName(uint256 chainId) private view returns (string memory) {
        return DeploymentRecorder._hooksName(
            DeploymentUtils._getSymbol(vm, helperConfig.getDeployedToken(chainId)), _hooksPoolType()
        );
    }

    function _hooksPoolType() private view returns (string memory) {
        return vm.envOr("POOL_TYPE", string("BurnMint"));
    }
}
