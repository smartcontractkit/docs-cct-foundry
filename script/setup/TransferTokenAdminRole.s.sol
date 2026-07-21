// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/**
 * @notice Initiates a transfer of the token admin role to a new address.
 * @dev This is step 1 of a two-step process - the new admin must run AcceptAdminRole to complete it.
 *
 * Required env vars:
 *   NEW_ADMIN  - address of the new administrator
 *
 * Optional env vars:
 *   TOKEN      - inline alias for the token address (takes priority over {CHAIN}_TOKEN)
 *
 * Usage:
 *   NEW_ADMIN=0xNewAdminAddress forge script script/setup/TransferTokenAdminRole.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract TransferTokenAdminRole is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔄 Transfer Token Admin Role");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Transfer admin role"));
        console.log("========================================");
        console.log("");

        // Get deployed token address - TOKEN env var takes priority, then {CHAIN}_TOKEN
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set TOKEN or ", config.chainNameIdentifier, "_TOKEN environment variable."
            )
        );

        // Get new admin address from env var
        address newAdmin = vm.envAddress("NEW_ADMIN");
        require(newAdmin != address(0), "NEW_ADMIN environment variable must be set to a non-zero address");

        require(config.tokenAdminRegistry != address(0), "TokenAdminRegistry not defined for this network");

        TokenAdminRegistry tokenAdminRegistryContract = TokenAdminRegistry(config.tokenAdminRegistry);

        TokenAdminRegistry.TokenConfig memory tokenConfig = tokenAdminRegistryContract.getTokenConfig(tokenAddress);
        address currentAdmin = tokenConfig.administrator;
        address pendingAdmin = tokenConfig.pendingAdministrator;

        console.log("Transfer Admin Role Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Token Admin Registry:         ", vm.toString(config.tokenAdminRegistry)));
        console.log(string.concat("  Current Administrator:        ", vm.toString(currentAdmin)));
        console.log(string.concat("  Pending Administrator:        ", vm.toString(pendingAdmin)));
        console.log(string.concat("  New Admin:                    ", vm.toString(newAdmin)));

        address signer = _broadcaster();
        console.log(string.concat("  Signer:                       ", vm.toString(signer)));
        console.log("");

        require(
            currentAdmin != address(0),
            string.concat(
                "Current admin is zero address. ",
                pendingAdmin != address(0)
                    ? string.concat(
                        "The pending admin (", vm.toString(pendingAdmin), ") must call AcceptAdminRole first."
                    )
                    : "No admin has been claimed yet. Run ClaimAdmin then AcceptAdminRole first."
            )
        );

        require(
            currentAdmin == signer,
            string.concat(
                "Signer (",
                vm.toString(signer),
                ") is not the current administrator (",
                vm.toString(currentAdmin),
                "). Only the current admin can transfer the role."
            )
        );

        console.log(string.concat("\n[Step 1] Transferring admin role for token on ", chainName));
        _executeCalls(CctActions._transferAdminRole(config.tokenAdminRegistry, tokenAddress, newAdmin));
        console.log(unicode"✅ Admin role transfer initiated successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Admin Role Transfer Initiated on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token:       ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("New Admin:   ", vm.toString(newAdmin)));
        console.log("========================================");
        console.log("");
        console.log(
            string.concat(
                unicode"ℹ️  The new admin (",
                vm.toString(newAdmin),
                ") must run AcceptAdminRole to complete the transfer."
            )
        );
        console.log("");
    }
}
