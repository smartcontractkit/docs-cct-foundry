// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {CctActions} from "../../src/actions/CctActions.sol";
import {ClaimPathDetector} from "./ClaimPathDetector.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

contract ClaimAdmin is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"👑 Claim Token Admin");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Claim token admin"));
        console.log("========================================");
        console.log("");

        // Get deployed token address — TOKEN env var takes priority, then {CHAIN}_TOKEN
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set TOKEN or ", config.chainNameIdentifier, "_TOKEN environment variable."
            )
        );

        // Get RegistryModuleOwnerCustom address from config
        address registryModuleOwnerCustom = config.registryModuleOwnerCustom;
        require(registryModuleOwnerCustom != address(0), "RegistryModuleOwnerCustom not configured for this network");

        // Detect which self-registration path the token supports (getCCIPAdmin() preferred, then
        // owner(), then OZ AccessControl DEFAULT_ADMIN_ROLE).
        (ClaimPathDetector.ClaimPath claimPath, address reportedAdmin) = ClaimPathDetector.detect(tokenAddress);

        // The account that must execute the claim: the Safe in safe mode, the broadcaster otherwise.
        address ccipAdminAddress = vm.envOr("CCIP_ADMIN_ADDRESS", executingAccount());

        // The getCCIPAdmin()/owner() paths report a single current admin; the AccessControl path has no
        // single-admin getter, so the expected role holder stands in for the log line.
        address currentAdmin =
            claimPath == ClaimPathDetector.ClaimPath.AccessControlDefaultAdmin ? ccipAdminAddress : reportedAdmin;

        console.log("Claim Admin Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Current Admin:                ", vm.toString(currentAdmin)));
        console.log(string.concat("  Expected Admin:               ", vm.toString(ccipAdminAddress)));
        console.log(string.concat("  Registry Module:              ", vm.toString(registryModuleOwnerCustom)));
        console.log(string.concat("  Admin Method:                 ", ClaimPathDetector.methodLabel(claimPath)));
        console.log("");

        ClaimPathDetector.requireExpectedAdmin(claimPath, tokenAddress, reportedAdmin, ccipAdminAddress);

        // Build the claim through the shared action layer and broadcast it as an EOA.
        CctActions.Call[] memory calls;
        if (claimPath == ClaimPathDetector.ClaimPath.GetCCIPAdmin) {
            console.log(string.concat("\n[Step 1] Claiming admin for token via getCCIPAdmin() on ", chainName));
            calls = CctActions.registerAdminViaGetCCIPAdmin(registryModuleOwnerCustom, tokenAddress);
        } else if (claimPath == ClaimPathDetector.ClaimPath.Owner) {
            console.log(string.concat("\n[Step 1] Claiming admin for token via owner() on ", chainName));
            calls = CctActions.registerAdminViaOwner(registryModuleOwnerCustom, tokenAddress);
        } else {
            console.log(
                string.concat("\n[Step 1] Claiming admin for token via AccessControl DEFAULT_ADMIN_ROLE on ", chainName)
            );
            calls = CctActions.registerAccessControlDefaultAdmin(registryModuleOwnerCustom, tokenAddress);
        }
        executeCalls(calls);
        console.log(unicode"✅ Admin claimed successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Admin Claim Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Address: ", vm.toString(tokenAddress)));
        console.log(string.concat("Token Address: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("Admin Address: ", vm.toString(ccipAdminAddress)));
        console.log("========================================");
        console.log("");
    }
}
