// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";

/// @notice Reads and displays the typeAndVersion string from any contract implementing ITypeAndVersion.
/// Reverts with a descriptive message if the contract does not expose typeAndVersion()
/// (i.e. does not inherit ITypeAndVersion).
///
/// Required env vars:
///   ADDRESS - contract address to query
///
/// Usage example:
///   ADDRESS=0xYourContract forge script script/setup/GetTypeAndVersion.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetTypeAndVersion is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address contractAddress = vm.envAddress("ADDRESS");
        require(contractAddress != address(0), "ADDRESS must be a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(unicode"🔍 Get Type and Version");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Contract:     ", vm.toString(contractAddress)));
        console.log(string.concat("Action:       ", "Read typeAndVersion"));
        console.log("========================================");
        console.log("");

        (bool success, bytes memory data) = contractAddress.staticcall(abi.encodeWithSignature("typeAndVersion()"));
        require(
            success,
            string.concat(
                "Contract at ",
                vm.toString(contractAddress),
                " does not implement ITypeAndVersion (typeAndVersion() call failed)"
            )
        );

        string memory version = abi.decode(data, (string));

        console.log(string.concat("typeAndVersion: ", version));
        console.log("");
        console.log("========================================");
        console.log(string.concat("Contract:     ", helperConfig.getExplorerUrl(chainId, "/address/", contractAddress)));
        console.log("========================================");
        console.log("");
    }
}
