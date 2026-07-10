// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {HelperUtils} from "../utils/HelperUtils.s.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {DeploymentUtils} from "../utils/DeploymentUtils.s.sol";
import {DeploymentRecorder} from "../utils/DeploymentRecorder.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/**
 * @title DeployERC20LockBox
 * @notice Script to deploy an ERC20LockBox for use with a LockReleaseTokenPool
 * @dev ERC20LockBox holds ERC20 liquidity so pools can be upgraded without migrating funds.
 *      After deployment, authorize the token pool address via applyAuthorizedCallerUpdates.
 *
 * Usage:
 *   forge script script/deploy/DeployERC20LockBox.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   AUTHORIZED_CALLERS   — (optional) CSV or JSON array of addresses to authorize immediately
 *                          (e.g. deployer/token issuer for initial liquidity management)
 */
contract DeployERC20LockBox is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        string memory chainNameId = helperConfig.getNetworkConfig(chainId).chainNameIdentifier;

        console.log("");
        console.log("========================================");
        console.log(unicode"📦 Deploy ERC20 LockBox");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Deploy ERC20 lockbox"));
        console.log("========================================");
        console.log("");

        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat("Token not deployed. Set TOKEN or ", chainNameId, "_TOKEN environment variable.")
        );

        // Parse optional authorized callers to add immediately after deployment
        string memory callersEnv = vm.envOr("AUTHORIZED_CALLERS", string(""));
        address[] memory authorizedCallers = HelperUtils.parseAddressArray(vm, callersEnv, "");

        console.log("ERC20LockBox Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        if (authorizedCallers.length > 0) {
            console.log(string.concat("  Authorized Callers:           ", vm.toString(authorizedCallers.length)));
            for (uint256 i = 0; i < authorizedCallers.length; i++) {
                console.log(string.concat("    [", vm.toString(i), "] ", vm.toString(authorizedCallers[i])));
            }
        } else {
            console.log(string.concat("  Authorized Callers:           ", "None (add after deploying the token pool)"));
        }
        console.log("");

        // Refuse to redeploy over a live registry entry (FORCE_REDEPLOY=true overrides). Keyed on the
        // unique per-symbol deployment name so distinct tokens on one chain never collide.
        RegistryWriter.guard(chainId, DeploymentRecorder.lockBoxName(DeploymentUtils.getSymbol(vm, tokenAddress)));

        vm.startBroadcast();

        console.log(string.concat("\n[Step 1] Deploying ERC20LockBox on ", chainName));
        ERC20LockBox lockBox = new ERC20LockBox(tokenAddress);
        address lockBoxAddress = address(lockBox);
        console.log(string.concat("ERC20LockBox deployed at: ", vm.toString(lockBoxAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", lockBoxAddress));
        console.log(unicode"✅ ERC20LockBox deployed successfully!");

        if (authorizedCallers.length > 0) {
            console.log("\n[Step 2] Authorizing callers...");
            lockBox.applyAuthorizedCallerUpdates(
                AuthorizedCallers.AuthorizedCallerArgs({
                    addedCallers: authorizedCallers, removedCallers: new address[](0)
                })
            );
            console.log(unicode"✅ Authorized callers set successfully!");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deployment Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("ERC20LockBox Address: ", vm.toString(lockBoxAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", lockBoxAddress));
        console.log("");
        // Single writer: one call emits the detailed ledger file AND records the address in the
        // registry (deployments[{symbol}_LockBox] + active.lockBox).
        DeploymentRecorder.recordLockBox(vm, chainId, chainNameId, lockBoxAddress, tokenAddress);
        console.log("");
        console.log("The address is registered in the address registry; later scripts resolve it automatically.");
        console.log("Copy this address to use in the next commands:");
        console.log(string.concat("  LOCK_BOX=", vm.toString(lockBoxAddress)));
        if (authorizedCallers.length == 0) {
            console.log("");
            console.log("Next Steps:");
            console.log(string.concat("  1. Deploy a LockReleaseTokenPool with LOCK_BOX=", vm.toString(lockBoxAddress)));
            console.log("  2. Authorize the pool on the lockbox:");
            console.log(
                string.concat(
                    "     LOCK_BOX=",
                    vm.toString(lockBoxAddress),
                    " ADD_ADDRESSES=<TOKEN_POOL_ADDRESS>",
                    " forge script script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol",
                    " --rpc-url $",
                    chainNameId,
                    "_RPC_URL --account $KEYSTORE_NAME --broadcast"
                )
            );
        }
        console.log("========================================");
        console.log("");
    }
}
