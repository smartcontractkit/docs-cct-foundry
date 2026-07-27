// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {ChainHandlers} from "../../utils/ChainHandlers.s.sol";
import {AddressEncoding} from "../../utils/AddressEncoding.s.sol";

/// @notice Reads and displays the remote token configured on a TokenPool for a given remote chain.
///
/// Environment Variables (required):
///   DEST_CHAIN   - The remote chain whose token address is being queried (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (optional):
///   DEST_CHAIN_FAMILY   - Override destination family (default: from DEST_CHAIN config)
///   DEST_CHAIN_SELECTOR - Override destination selector (default: from DEST_CHAIN config)
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/remote-pools/GetRemoteToken.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetRemoteToken is Script {
    HelperConfig public helperConfig;

    function run() external {
        // -- Required env vars -------------------------------------------------
        string memory destChainName = vm.envString("DEST_CHAIN");

        // -- Resolve selector/family from destination config (EVM and non-EVM)
        helperConfig = new HelperConfig();
        uint256 sourceChainId = block.chainid;
        HelperConfig.NetworkConfig memory destConfig = helperConfig.getDestChainConfig(destChainName);
        string memory destChainFamilyStr = vm.envOr(
            "DEST_CHAIN_FAMILY", bytes(destConfig.chainFamily).length > 0 ? destConfig.chainFamily : string("evm")
        );
        ChainHandlers.ChainFamily destChainFamily = ChainHandlers._parseChainFamily(destChainFamilyStr);
        uint64 remoteChainSelector = uint64(vm.envOr("DEST_CHAIN_SELECTOR", uint256(destConfig.chainSelector)));
        require(
            remoteChainSelector != 0, "Chain selector is not defined for destination chain. Set DEST_CHAIN_SELECTOR."
        );

        string memory sourceChainName = helperConfig.getChainName(sourceChainId);
        string memory remoteChainDisplayName =
            bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;

        // -- Resolve local token pool -----------------------------------------
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // -- Header ------------------------------------------------------------
        console.log("");
        console.log("========================================");
        console.log(unicode"🪙 Get Remote Token");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", remoteChainDisplayName));
        console.log(string.concat("Remote Family:", " ", destChainFamilyStr));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View remote token"));
        console.log("========================================");
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        bool isSupported = tokenPool.isSupportedChain(remoteChainSelector);
        console.log(string.concat("Chain Supported: ", isSupported ? "Yes" : "No"));

        if (isSupported) {
            bytes memory remoteToken = tokenPool.getRemoteToken(remoteChainSelector);
            if (destChainFamily == ChainHandlers.ChainFamily.EVM && AddressEncoding._isAbiEncodedAddress(remoteToken)) {
                address tokenAddr = abi.decode(remoteToken, (address));
                console.log(string.concat("Remote Token:    ", vm.toString(tokenAddr)));
            } else {
                console.log(string.concat("Remote Token:    (raw) ", vm.toString(remoteToken)));
            }
        }

        console.log("");
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
