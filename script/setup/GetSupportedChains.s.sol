// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {ChainHandlers} from "../utils/ChainHandlers.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {PoolVersion} from "../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";

/// @notice Reads and displays all remote chains supported by a TokenPool.
///
/// Usage example:
///   forge script script/setup/GetSupportedChains.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetSupportedChains is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Resolve chain ID ──────────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Get Supported Chains");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View supported chains"));
        console.log("========================================");
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // Read-only path: resolve the version to pick the right getter (getRemotePool singular on
        // 1.5.0, getRemotePools from 1.5.1); an unrecognized version warns and degrades to best
        // effort instead of refusing.
        (bool versionKnown, PoolVersions.Version version, string memory poolTypeAndVersion) =
            PoolVersion._tryResolve(tokenPoolAddress);
        if (versionKnown) {
            console.log(string.concat("Pool Version: ", poolTypeAndVersion));
        } else {
            console.log(
                string.concat(
                    unicode"⚠️  WARN: unrecognized pool version \"",
                    poolTypeAndVersion,
                    unicode"\"; read-only display, best effort."
                )
            );
        }

        uint64[] memory supportedChains = tokenPool.getSupportedChains();

        console.log(string.concat("Supported Remote Chains: ", vm.toString(supportedChains.length)));
        console.log("");

        for (uint256 i = 0; i < supportedChains.length; i++) {
            uint64 selector = supportedChains[i];
            bytes[] memory remotePools = PoolVersion._remotePools(tokenPoolAddress, version, selector);
            // Resolve the remote's family from its config by SELECTOR (not by display name):
            // getChainNameBySelector returns the displayName ("Solana Devnet") but getDestChainConfig
            // matches the identifier ("SOLANA_DEVNET"), so the round-trip misses for non-EVM chains
            // and falls back to a zero/evm config - which would misdecode SVM pubkeys as EVM addresses
            // and never reach the base58 branch. The selector-based lookup resolves the family directly.
            HelperConfig.NetworkConfig memory remoteConfig = helperConfig.getDestChainConfigBySelector(selector);
            string memory remoteChainName = bytes(remoteConfig.chainName).length > 0
                ? remoteConfig.chainName
                : helperConfig.getChainNameBySelector(selector);
            bool familyKnown = bytes(remoteConfig.chainFamily).length > 0;
            ChainHandlers.ChainFamily remoteFamily =
                ChainHandlers._parseChainFamily(familyKnown ? remoteConfig.chainFamily : string("evm"));
            console.log(string.concat("  [", vm.toString(i), "] ", remoteChainName, " (", vm.toString(selector), ")"));
            if (!familyKnown) {
                console.log(
                    string.concat(
                        unicode"       ⚠️  WARN: selector ",
                        vm.toString(selector),
                        " is not in config/chains (unknown family) - add the chain with `make add-chain` so its family is resolved. Addresses below are rendered as raw hex."
                    )
                );
            }
            console.log(string.concat("       Remote Pools: ", vm.toString(remotePools.length)));
            for (uint256 j = 0; j < remotePools.length; j++) {
                bytes memory pool = remotePools[j];
                console.log(
                    string.concat("         [", vm.toString(j), "] ", ChainHandlers._formatAddress(remoteFamily, pool))
                );
            }
        }

        console.log("");
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
