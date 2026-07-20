// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Accepts the pending administrator role for a token in the TokenAdminRegistry (step 2 of the
///         two-step claim; the signer must be the pending administrator set by ClaimAdmin).
contract AcceptAdminRole is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"👑 Accept Admin Role");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Accept admin role"));
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

        // Validate TokenAdminRegistry address
        require(config.tokenAdminRegistry != address(0), "TokenAdminRegistry not defined for this network");

        // Instantiate the TokenAdminRegistry contract
        TokenAdminRegistry tokenAdminRegistryContract = TokenAdminRegistry(config.tokenAdminRegistry);

        // Fetch the token configuration
        TokenAdminRegistry.TokenConfig memory tokenConfig = tokenAdminRegistryContract.getTokenConfig(tokenAddress);
        address pendingAdministrator = tokenConfig.pendingAdministrator;

        console.log("Accept Admin Role Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Token Admin Registry:         ", vm.toString(config.tokenAdminRegistry)));
        console.log(string.concat("  Pending Administrator:        ", vm.toString(pendingAdministrator)));

        // The account accepting on-chain: the Safe in safe mode, the broadcaster otherwise.
        address acceptor = _executingAccount();
        console.log(string.concat("  Acceptor:                     ", vm.toString(acceptor)));
        console.log("");

        require(pendingAdministrator == acceptor, "Only the pending administrator can accept the admin role");

        console.log(string.concat("\n[Step 1] Accepting admin role for token on ", chainName));
        _executeCalls(CctActions._acceptAdminRole(config.tokenAdminRegistry, tokenAddress));
        console.log(unicode"✅ Admin role accepted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Admin Role Accepted on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Address: ", vm.toString(tokenAddress)));
        console.log(string.concat("Token Address: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenAddress)));
        console.log(string.concat("New Administrator: ", vm.toString(acceptor)));
        console.log("========================================");
        console.log("");
    }
}
