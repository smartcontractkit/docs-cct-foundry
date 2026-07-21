// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Points the TokenAdminRegistry at the token's pool, activating the token for cross-chain transfers.
contract SetPool is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address poolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            poolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set TOKEN_POOL or ",
                config.chainNameIdentifier,
                "_TOKEN_POOL environment variable."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🏊‍♂️ Set Token Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(poolAddress)));
        console.log(string.concat("Action:       ", "Set token pool"));
        console.log("========================================");
        console.log("");

        // Get deployed token address from environment variable
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set TOKEN or ", config.chainNameIdentifier, "_TOKEN environment variable."
            )
        );

        // Validate TokenAdminRegistry address
        require(config.tokenAdminRegistry != address(0), "TokenAdminRegistry not defined for this network");

        // Instantiate the TokenAdminRegistry contract
        TokenAdminRegistry tokenAdminRegistryContract = TokenAdminRegistry(config.tokenAdminRegistry);

        // Fetch the token configuration to get the administrator's address
        TokenAdminRegistry.TokenConfig memory tokenConfig = tokenAdminRegistryContract.getTokenConfig(tokenAddress);
        address tokenAdministratorAddress = tokenConfig.administrator;

        console.log("Set Pool Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Pool:                         ", vm.toString(poolAddress)));
        console.log(string.concat("  Token Admin Registry:         ", vm.toString(config.tokenAdminRegistry)));
        console.log(string.concat("  Token Administrator:          ", vm.toString(tokenAdministratorAddress)));
        console.log("");

        console.log(string.concat("\n[Step 1] Setting pool for token on ", chainName));
        _executeCalls(CctActions._setPool(config.tokenAdminRegistry, tokenAddress, poolAddress));
        console.log(unicode"✅ Pool set successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Pool Set Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Address: ", vm.toString(tokenAddress)));
        console.log(string.concat("Token Address: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("Pool Address:  ", vm.toString(poolAddress)));
        console.log(string.concat("Pool Address:  ", helperConfig.getExplorerUrl(chainId, "/address/", poolAddress)));
        console.log("========================================");
        console.log("");
    }
}
