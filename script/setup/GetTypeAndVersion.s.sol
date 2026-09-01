// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {TolerantCall} from "../../src/utils/TolerantCall.sol";

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

        string memory version = _readVersionOrRefuse(contractAddress);

        console.log(string.concat("typeAndVersion: ", version));
        console.log("");
        console.log("========================================");
        console.log(string.concat("Contract:     ", helperConfig.getExplorerUrl(chainId, "/address/", contractAddress)));
        console.log("========================================");
        console.log("");
    }

    /// @dev Refusing is correct here; refusing by NAME is the change. The raw decode this replaces
    /// reverted with no reason on an address that ANSWERED undecodably.
    function _readVersionOrRefuse(address contractAddress) internal view returns (string memory version) {
        bool readable;
        (readable, version) = TolerantCall._tryString(contractAddress, "typeAndVersion()");
        require(
            readable,
            string.concat(
                "Contract at ",
                vm.toString(contractAddress),
                " does not implement ITypeAndVersion (no code, or typeAndVersion() did not answer)"
            )
        );
    }

    /// @dev Test seam: the refusal above is the whole behavior worth pinning, and `run()` reaches it
    /// only through an env var, which is process-wide while suites run in parallel.
    function readVersionForTest(address contractAddress) external view returns (string memory) {
        return _readVersionOrRefuse(contractAddress);
    }
}
