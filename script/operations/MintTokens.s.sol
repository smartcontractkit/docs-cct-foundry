// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Mints tokens to a receiver (requires the signer to hold the token's minter role).
contract MintTokens is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"💰 Mint Tokens");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Mint tokens"));
        console.log("========================================");
        console.log("");

        // Get deployed token address - TOKEN env var takes priority, then {CHAIN}_TOKEN
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN environment variable. Alternatively, use the inline alias TOKEN=0x..."
            )
        );

        // Get amount to mint - falls back to tokenAmountToMint in script/input/token.json if not set
        string memory tokenJson = vm.readFile("script/input/token.json");
        uint256 defaultMintAmount = vm.parseJsonUint(tokenJson, ".tokenAmountToMint");
        uint256 amount = vm.envOr("AMOUNT", defaultMintAmount);
        require(
            amount > 0, "Invalid amount to mint. Set AMOUNT env var or tokenAmountToMint in script/input/token.json"
        );

        CrossChainToken token = CrossChainToken(tokenAddress);

        console.log("Mint Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Token Symbol:                 ", token.symbol()));
        console.log(string.concat("  Amount:                       ", vm.toString(amount)));

        // Get receiver address from environment variable or use broadcaster by default
        address receiverAddress = vm.envOr("MINT_RECEIVER", _broadcaster());
        console.log(string.concat("  Receiver:                     ", vm.toString(receiverAddress)));
        console.log("");

        console.log(
            string.concat(
                "\n[Step 1] Minting ", vm.toString(amount), " ", token.symbol(), " to ", vm.toString(receiverAddress)
            )
        );
        _executeCalls(CctActions._mint(tokenAddress, receiverAddress, amount));
        console.log(unicode"✅ Tokens minted successfully!");

        uint256 newBalance = token.balanceOf(receiverAddress);

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Minting Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Receiver Address: ", vm.toString(receiverAddress)));
        console.log(
            string.concat("Receiver Address: ", helperConfig.getExplorerUrl(chainId, "/address/", receiverAddress))
        );
        console.log(string.concat("New Balance: ", vm.toString(newBalance), " ", token.symbol()));
        console.log("========================================");
        console.log("");
    }
}
