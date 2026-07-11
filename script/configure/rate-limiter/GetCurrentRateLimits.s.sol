// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiterUtils, ITokenPoolV1RateLimiter} from "../../utils/RateLimiterUtils.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Reads and displays the current rate limiter state for a TokenPool, compatible with v1 and v2 pools.
///
/// Environment Variables (required):
///   DEST_CHAIN    - The remote chain whose lane is being queried (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (optional, v2 only):
///   FAST_FINALITY - true/false, whether to read the fast finality bucket
///                   (default: false, reads the standard finality bucket)
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/rate-limiter/GetCurrentRateLimits.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetCurrentRateLimits is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");

        // ── Optional env vars ──────────────────────────────────────────────
        bool fastFinality = vm.envOr("FAST_FINALITY", false);

        // ── Resolve chain IDs and selectors ───────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        uint64 remoteChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;

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
        console.log(unicode"📊 Get Current Rate Limits");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View rate limits"));
        if (fastFinality) {
            console.log("Bucket:       Custom finality (standard finality fallback per direction if not enabled)");
        } else {
            console.log("Bucket:       Standard finality");
        }
        console.log("========================================");
        console.log("");

        TokenPool poolV2 = TokenPool(tokenPoolAddress);
        ITokenPoolV1RateLimiter poolV1 = ITokenPoolV1RateLimiter(tokenPoolAddress);

        // Read-only path: an unrecognized pool version degrades to best effort with a warning
        // instead of refusing (only mutating scripts refuse on an unresolved version).
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
        console.log("");

        if (fastFinality && version >= PoolVersions.Version.V2_0_0) {
            RateLimiterUtils.logRateLimiterStateWithFallback(poolV2, poolV1, remoteChainSelector, version);
        } else {
            RateLimiterUtils.logRateLimiterState(poolV2, poolV1, remoteChainSelector, fastFinality, version);
        }

        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
    }
}
