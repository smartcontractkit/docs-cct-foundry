// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Reads and displays the remote pool addresses configured on a TokenPool for a given remote chain.
///
/// Environment Variables (required):
///   DEST_CHAIN   - The remote chain whose pool addresses are being queried (e.g. MANTLE_SEPOLIA)
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/remote-pools/GetRemotePools.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetRemotePools is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");

        // ── Resolve chain IDs and selectors ───────────────────────────────
        helperConfig = new HelperConfig();
        uint256 sourceChainId = block.chainid;
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        string memory sourceChainName = helperConfig.getChainName(sourceChainId);
        uint64 remoteChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(sourceChainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(sourceChainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🏊 Get Remote Pools");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View remote pools"));
        console.log("========================================");
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // Read-only path: resolve the version to pick the right getter (getRemotePool singular on
        // 1.5.0, getRemotePools from 1.5.1); an unrecognized version warns and degrades to best
        // effort instead of refusing.
        (bool versionKnown, PoolVersions.Version version, string memory poolTypeAndVersion) =
            PoolVersion.tryResolve(tokenPoolAddress);
        if (versionKnown) {
            console.log(string.concat("Pool Version:    ", poolTypeAndVersion));
        } else {
            console.log(
                string.concat(
                    unicode"⚠️  WARN: unrecognized pool version \"",
                    poolTypeAndVersion,
                    unicode"\"; read-only display, best effort."
                )
            );
        }

        bool isSupported = tokenPool.isSupportedChain(remoteChainSelector);
        console.log(string.concat("Chain Supported: ", isSupported ? "Yes" : "No"));

        if (isSupported) {
            bytes[] memory remotePools = PoolVersion.remotePools(tokenPoolAddress, version, remoteChainSelector);
            console.log(string.concat("Remote Pools:    ", vm.toString(remotePools.length)));
            for (uint256 i = 0; i < remotePools.length; i++) {
                if (remotePools[i].length == 32) {
                    address poolAddr = abi.decode(remotePools[i], (address));
                    console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(poolAddr)));
                } else {
                    console.log(string.concat("  [", vm.toString(i), "] (raw) ", vm.toString(remotePools[i])));
                }
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
