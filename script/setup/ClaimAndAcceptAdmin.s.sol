// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/contracts/interfaces/IGetCCIPAdmin.sol";
import {IOwner} from "@chainlink/contracts-ccip/contracts/interfaces/IOwner.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Claims AND accepts the CCIP token admin as ONE atomic registration pair — the claim sets
/// the executing account as the registry's pending administrator, so the accept in the same batch
/// succeeds. This is the batch-friendly counterpart of running `ClaimAdmin` then `AcceptAdminRole`:
/// `AcceptAdminRole` preflight-requires the pending administrator to ALREADY be set when the script
/// runs, so the two-script sequence cannot be composed into one deferred Safe batch — this wrapper
/// can, because the pair executes together. It uses the same claim-path probe as `ClaimAdmin`
/// (getCCIPAdmin() preferred, owner() fallback).
///
/// In Safe mode, set CCIP_ADMIN_ADDRESS to the Safe: the Safe is the account executing the pair, so
/// it must be the token's current CCIP admin (or owner) and becomes the registry administrator.
///
/// Environment Variables:
///   TOKEN / <CHAIN>_TOKEN   (required) the token to register
///   CCIP_ADMIN_ADDRESS      (optional) expected current admin; defaults to the executing account
///                           (the Safe in safe mode, the broadcaster otherwise).
contract ClaimAndAcceptAdmin is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"👑 Claim + Accept Token Admin (one batch)");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Claim and accept token admin atomically"));
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

        address registryModuleOwnerCustom = config.registryModuleOwnerCustom;
        require(registryModuleOwnerCustom != address(0), "RegistryModuleOwnerCustom not configured for this network");
        address tokenAdminRegistry = config.tokenAdminRegistry;
        require(tokenAdminRegistry != address(0), "TokenAdminRegistry not configured for this network");

        // Same claim-path probe as ClaimAdmin: getCCIPAdmin() preferred, owner() fallback.
        address currentAdmin;
        bool useCCIPAdmin = false;
        try IGetCCIPAdmin(tokenAddress).getCCIPAdmin() returns (address admin) {
            currentAdmin = admin;
            useCCIPAdmin = true;
        } catch {
            try IOwner(tokenAddress).owner() returns (address admin) {
                currentAdmin = admin;
                useCCIPAdmin = false;
            } catch {
                revert("Token must implement either getCCIPAdmin() or owner()");
            }
        }

        // The account that must execute the pair: the Safe in safe mode, the broadcaster otherwise.
        address ccipAdminAddress = vm.envOr("CCIP_ADMIN_ADDRESS", executingAccount());

        console.log("Registration Pair Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Current Admin:                ", vm.toString(currentAdmin)));
        console.log(string.concat("  Expected Admin:               ", vm.toString(ccipAdminAddress)));
        console.log(string.concat("  Registry Module:              ", vm.toString(registryModuleOwnerCustom)));
        console.log(string.concat("  TokenAdminRegistry:           ", vm.toString(tokenAdminRegistry)));
        console.log(string.concat("  Admin Method:                 ", useCCIPAdmin ? "getCCIPAdmin()" : "owner()"));
        console.log("");

        require(currentAdmin == ccipAdminAddress, "Admin of token doesn't match the expected admin address");

        CctActions.Call[] memory calls;
        if (useCCIPAdmin) {
            console.log(string.concat("\n[Step 1] Claiming + accepting admin via getCCIPAdmin() on ", chainName));
            calls = CctActions.registerAndAcceptAdminViaGetCCIPAdmin(
                registryModuleOwnerCustom, tokenAdminRegistry, tokenAddress
            );
        } else {
            console.log(string.concat("\n[Step 1] Claiming + accepting admin via owner() on ", chainName));
            calls =
                CctActions.registerAndAcceptAdminViaOwner(registryModuleOwnerCustom, tokenAdminRegistry, tokenAddress);
        }
        executeCalls(calls);
        console.log(unicode"✅ Registration pair executed!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Claim + Accept Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Address: ", vm.toString(tokenAddress)));
        console.log(string.concat("Token Address: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("Admin Address: ", vm.toString(ccipAdminAddress)));
        console.log("========================================");
        console.log("");
    }
}
