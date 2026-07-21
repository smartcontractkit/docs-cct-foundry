// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperUtils} from "../utils/HelperUtils.s.sol"; // Utility functions for JSON parsing and chain info
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {DeploymentRecorder} from "../utils/DeploymentRecorder.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {BaseERC20} from "@chainlink/contracts-ccip/contracts/tokens/BaseERC20.sol";
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";

/// @notice Deploys a cross-chain ERC20 token (CrossChainToken) and records it in the address registry.
contract DeployToken is Script {
    HelperConfig public helperConfig;

    struct TokenConfig {
        string name;
        string symbol;
        uint8 decimals;
        uint256 maxSupply;
        uint256 preMint;
        address preMintRecipient;
        address ccipAdmin;
    }

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        string memory selectorName = helperConfig.getSelectorName(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"🪙 Deploy Token");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Deploy token"));
        console.log("========================================");
        console.log("");

        string memory root = vm.projectRoot();
        string memory tokenConfigPath = string.concat(root, "/script/input/token.json");

        TokenConfig memory tokenConfig = _loadTokenConfig(tokenConfigPath);

        // Refuse to redeploy over a live registry entry (FORCE_REDEPLOY=true overrides). Keyed on the
        // unique deployment name so distinct symbols on one chain never collide.
        RegistryWriter._guard(selectorName, DeploymentRecorder._tokenName(tokenConfig.symbol));

        vm.startBroadcast();

        (, address broadcaster,) = vm.readCallers();

        // Default preMintRecipient to broadcaster if a pre-mint is requested but no recipient was specified
        if (tokenConfig.preMint > 0 && tokenConfig.preMintRecipient == address(0)) {
            tokenConfig.preMintRecipient = broadcaster;
        }

        console.log(string.concat("  Pre-mint Recipient:           ", vm.toString(tokenConfig.preMintRecipient)));
        // ccipAdmin address(0) resolves to msg.sender (broadcaster) inside BaseERC20 constructor
        console.log(
            string.concat(
                "  CCIP Admin:                   ",
                tokenConfig.ccipAdmin == address(0) ? vm.toString(broadcaster) : vm.toString(tokenConfig.ccipAdmin)
            )
        );
        console.log("");

        console.log(
            string.concat("\n[Step 1] Deploying ", tokenConfig.name, " (", tokenConfig.symbol, ") on ", chainName)
        );
        BaseERC20.ConstructorParams memory params = BaseERC20.ConstructorParams({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            maxSupply: tokenConfig.maxSupply,
            preMint: tokenConfig.preMint,
            preMintRecipient: tokenConfig.preMintRecipient,
            decimals: tokenConfig.decimals,
            ccipAdmin: tokenConfig.ccipAdmin
        });
        CrossChainToken token = new CrossChainToken(params, broadcaster, address(0));
        address tokenAddress = address(token);
        console.log(string.concat("Token deployed at: ", vm.toString(tokenAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress));

        // Grant mint and burn roles to the specified address
        address rolesRecipient = vm.envOr("ROLES_RECIPIENT", broadcaster); // Default to deployer if not set
        console.log(string.concat("\n[Step 2] Granting mint and burn roles to: ", vm.toString(rolesRecipient)));
        token.grantMintAndBurnRoles(rolesRecipient);
        console.log(unicode"✅ Roles granted successfully!");

        vm.stopBroadcast();

        string memory chainNameIdentifier = helperConfig.getNetworkConfig(chainId).chainNameIdentifier;

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deployment Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Address: ", vm.toString(tokenAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress));
        console.log("");
        // Single writer: one call emits the detailed ledger file AND records the address in the
        // registry (deployments[{symbol}_Token] + active.token).
        DeploymentRecorder._recordToken(vm, selectorName, chainNameIdentifier, tokenConfig.symbol, tokenAddress);
        console.log("");
        console.log("The address is registered in the address registry; later scripts resolve it automatically.");
        console.log("To override it for a session, set the environment variable:");
        console.log(string.concat("export ", chainNameIdentifier, "_TOKEN=", vm.toString(tokenAddress)));
        console.log("========================================");
        console.log("");
    }

    /// @dev Reads token parameters from env vars (with JSON config as fallback), logs them,
    /// and returns a TokenConfig struct ready for deployment.
    /// @param tokenConfigPath Absolute path to the token JSON config file (e.g. `script/input/token.json`)
    /// @return config Populated TokenConfig struct with name, symbol, decimals, maxSupply, and preMint
    function _loadTokenConfig(string memory tokenConfigPath) internal view returns (TokenConfig memory config) {
        config.name = vm.envOr("TOKEN_NAME", HelperUtils._getStringFromJson(vm, tokenConfigPath, ".name"));
        config.symbol = vm.envOr("TOKEN_SYMBOL", HelperUtils._getStringFromJson(vm, tokenConfigPath, ".symbol"));
        config.decimals =
            uint8(vm.envOr("TOKEN_DECIMALS", HelperUtils._getUintFromJson(vm, tokenConfigPath, ".decimals")));
        config.maxSupply = vm.envOr("TOKEN_MAX_SUPPLY", HelperUtils._getUintFromJson(vm, tokenConfigPath, ".maxSupply"));
        config.preMint = vm.envOr("TOKEN_PRE_MINT", HelperUtils._getUintFromJson(vm, tokenConfigPath, ".preMint"));
        config.preMintRecipient = vm.envOr("TOKEN_PRE_MINT_RECIPIENT", address(0));
        config.ccipAdmin = vm.envOr("CCIP_ADMIN_ADDRESS", address(0));

        console.log("Token Parameters:");
        console.log(string.concat("  Name:                         ", config.name));
        console.log(string.concat("  Symbol:                       ", config.symbol));
        console.log(string.concat("  Decimals:                     ", vm.toString(config.decimals)));
        console.log(string.concat("  Max Supply:                   ", vm.toString(config.maxSupply)));
        console.log(string.concat("  Pre-mint:                     ", vm.toString(config.preMint)));
        console.log("");
    }
}
