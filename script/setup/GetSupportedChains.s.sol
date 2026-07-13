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
            PoolVersion.tryResolve(tokenPoolAddress);
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
            bytes[] memory remotePools = PoolVersion.remotePools(tokenPoolAddress, version, selector);
            string memory remoteChainName = helperConfig.getChainNameBySelector(selector);
            console.log(string.concat("  [", vm.toString(i), "] ", remoteChainName, " (", vm.toString(selector), ")"));
            console.log(string.concat("       Remote Pools: ", vm.toString(remotePools.length)));
            for (uint256 j = 0; j < remotePools.length; j++) {
                bytes memory pool = remotePools[j];
                // ABI-encoded EVM address: 32 bytes with 12 leading zero bytes.
                // Raw SVM pubkey: 32 bytes, no leading-zero padding.
                if (pool.length == 32 && _isEvmEncoded(pool)) {
                    console.log(
                        string.concat("         [", vm.toString(j), "] ", vm.toString(abi.decode(pool, (address))))
                    );
                } else if (pool.length == 32) {
                    // Raw SVM (Solana) public key — display as base58
                    console.log(string.concat("         [", vm.toString(j), "] ", ChainHandlers.encodeBase58(pool)));
                } else {
                    console.log(string.concat("         [", vm.toString(j), "] (raw) ", vm.toString(pool)));
                }
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

    /// @dev Returns true if `data` looks like an ABI-encoded EVM address:
    ///      32 bytes where the first 12 bytes are all zero.
    function _isEvmEncoded(bytes memory data) private pure returns (bool) {
        for (uint256 i = 0; i < 12; i++) {
            if (data[i] != 0) return false;
        }
        return true;
    }
}
