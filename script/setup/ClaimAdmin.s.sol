// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/contracts/interfaces/IGetCCIPAdmin.sol";
import {IOwner} from "@chainlink/contracts-ccip/contracts/interfaces/IOwner.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
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

        // Try to detect which admin function the token supports
        address currentAdmin;
        bool useCCIPAdmin = false;

        // Try getCCIPAdmin() first
        try IGetCCIPAdmin(tokenAddress).getCCIPAdmin() returns (address admin) {
            currentAdmin = admin;
            useCCIPAdmin = true;
        } catch {
            // If getCCIPAdmin() fails, try owner()
            try IOwner(tokenAddress).owner() returns (address admin) {
                currentAdmin = admin;
                useCCIPAdmin = false;
            } catch {
                revert("Token must implement either getCCIPAdmin() or owner()");
            }
        }

        // The account that must execute the claim: the Safe in safe mode, the broadcaster otherwise.
        address ccipAdminAddress = vm.envOr("CCIP_ADMIN_ADDRESS", executingAccount());

        console.log("Claim Admin Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Current Admin:                ", vm.toString(currentAdmin)));
        console.log(string.concat("  Expected Admin:               ", vm.toString(ccipAdminAddress)));
        console.log(string.concat("  Registry Module:              ", vm.toString(registryModuleOwnerCustom)));
        console.log(string.concat("  Admin Method:                 ", useCCIPAdmin ? "getCCIPAdmin()" : "owner()"));
        console.log("");

        require(currentAdmin == ccipAdminAddress, "Admin of token doesn't match the expected admin address");

        // Build the claim through the shared action layer and broadcast it as an EOA.
        CctActions.Call[] memory calls;
        if (useCCIPAdmin) {
            console.log(string.concat("\n[Step 1] Claiming admin for token via getCCIPAdmin() on ", chainName));
            calls = CctActions.registerAdminViaGetCCIPAdmin(registryModuleOwnerCustom, tokenAddress);
        } else {
            console.log(string.concat("\n[Step 1] Claiming admin for token via owner() on ", chainName));
            calls = CctActions.registerAdminViaOwner(registryModuleOwnerCustom, tokenAddress);
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
