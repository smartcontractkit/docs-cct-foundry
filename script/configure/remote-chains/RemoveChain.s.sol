// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions, ITokenPoolV150} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Fully unsupports a remote chain on the source TokenPool: removes the chain selector and
///         deletes its remote-chain config (pools, remote token, rate limits). After this call
///         `isSupportedChain` returns false and neither outbound `lockOrBurn` nor inbound
///         `releaseOrMint` accept the lane until it is added again with `applyChainUpdates`.
///
/// @dev This is the whole-lane teardown, distinct from `RemoveRemotePool` (which drops ONE remote
///      pool from a still-supported chain, 1.5.1+ only). Chain removal works on EVERY cataloged pool
///      version; only the on-chain encoding differs, and the script dispatches on the source pool's
///      `typeAndVersion` (see docs/pool-versions.md):
///        - 1.5.0 uses its single-argument `applyChainUpdates(ChainUpdate[])` with one `allowed:false`
///          entry (disabled, zeroed rate-limit configs, as the 1.5.0 validation requires).
///        - 1.5.1 and later use the modern `applyChainUpdates(uint64[] toRemove, ChainUpdate[] toAdd)`
///          with the selector in `toRemove` and an empty `toAdd`.
///
///      WARNING: All inflight transactions on this lane will be rejected after removal. Ensure there
///      are no inflight messages to or from this chain before removing it to avoid loss of funds.
///
/// Environment Variables (required):
///   DEST_CHAIN  - The remote chain to unsupport (e.g. MANTLE_SEPOLIA)
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/remote-chains/RemoveChain.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract RemoveChain is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");

        // ── Resolve chain IDs and selectors ───────────────────────────────
        helperConfig = new HelperConfig();
        uint256 sourceChainId = block.chainid;
        uint256 destChainId = helperConfig.parseChainName(destChainName);
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

        _removeChain(tokenPoolAddress, remoteChainSelector, destChainName, destChainId);
    }

    /// @dev Everything after input resolution. Split from run() so the version dispatch is testable
    ///      with an injected pool address (env-based pool resolution is process-global and cannot be
    ///      exercised race-free under parallel test suites), mirroring RemoveRemotePool.
    function _removeChain(
        address tokenPoolAddress,
        uint64 remoteChainSelector,
        string memory destChainName,
        uint256 destChainId
    ) internal {
        uint256 sourceChainId = block.chainid;
        string memory sourceChainName = helperConfig.getChainName(sourceChainId);

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // Pre-check: unsupporting a chain the pool does not support reverts NonExistentChain on-chain
        // (every version). Surface the friendly reason here rather than a raw contract revert.
        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat("Remote chain not supported on this pool (nothing to remove): ", destChainName)
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➖ Remove Remote Chain");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Unsupport remote chain (full lane teardown)"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Selector to Remove: ", vm.toString(remoteChainSelector)));
        console.log("");
        console.log(unicode"⚠️  WARNING: All inflight transactions on this lane will be rejected after removal.");
        console.log("   Ensure there are no inflight messages to or from this chain before proceeding.");
        console.log("");

        // ── Resolve the version BEFORE any version-shaped read ─────────────
        // A 1.5.0 pool has only the SINGULAR getRemotePool; reading the plural getRemotePools before
        // dispatch would raw-revert it and never reach the 1.5.0 encoding below. Resolve first, then
        // read through the version-safe helper (singular on 1.5.0, plural from 1.5.1) - the same
        // fence-before-read ordering RemoveRemotePool uses.
        (PoolVersions.Version poolVersion, string memory poolTypeAndVersion) = PoolVersion._resolve(tokenPoolAddress);
        console.log(string.concat("Pool contract: ", poolTypeAndVersion));
        console.log("");

        // ── Show current remote pools for the lane being torn down ─────────
        bytes[] memory currentPools = PoolVersion._remotePools(tokenPoolAddress, poolVersion, remoteChainSelector);
        console.log(string.concat("Current Remote Pools on this lane: ", vm.toString(currentPools.length)));
        for (uint256 i = 0; i < currentPools.length; i++) {
            if (currentPools[i].length == 32) {
                console.log(
                    string.concat("  [", vm.toString(i), "] ", vm.toString(abi.decode(currentPools[i], (address))))
                );
            } else {
                console.log(string.concat("  [", vm.toString(i), "] (raw) ", vm.toString(currentPools[i])));
            }
        }
        console.log("");

        console.log(string.concat("[Step 1] Removing remote chain on ", sourceChainName));

        _executeCalls(_buildChainRemovalCalls(poolVersion, tokenPoolAddress, remoteChainSelector));

        console.log(unicode"✅ Remote chain removed successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", sourceChainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Removed Chain:   ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Selector:        ", vm.toString(remoteChainSelector)));
        console.log(
            string.concat(
                "Token Pool:      ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev The exhaustive version switch for a whole-chain removal, matching ApplyChainUpdates'
    ///      lane-update dispatch: 1.5.0 takes the single-argument encoding with one `allowed:false`
    ///      entry, every later cataloged version takes the modern (removes[], adds[]) encoding with
    ///      the selector in removes[] and no adds[]. `PoolVersion._resolve` refuses uncataloged
    ///      versions before this switch runs, and a version added to the catalog without a branch
    ///      here fails loudly instead of falling through to the modern encoding.
    function _buildChainRemovalCalls(PoolVersions.Version version, address poolAddress, uint64 remoteChainSelector)
        internal
        pure
        returns (CctActions.Call[] memory)
    {
        if (version == PoolVersions.Version.V1_5_0) {
            console.log("Pool contract version 1.5.0 detected; using the 1.5.0 lane-update encoding.");
            ITokenPoolV150.ChainUpdate[] memory removals = new ITokenPoolV150.ChainUpdate[](1);
            removals[0] = ITokenPoolV150.ChainUpdate({
                remoteChainSelector: remoteChainSelector,
                allowed: false,
                remotePoolAddress: "",
                remoteTokenAddress: "",
                outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
                inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
            });
            return CctActions._applyChainUpdatesV150(poolAddress, removals);
        }
        if (
            version == PoolVersions.Version.V1_5_1 || version == PoolVersions.Version.V1_6_1
                || version == PoolVersions.Version.V2_0_0
        ) {
            uint64[] memory removes = new uint64[](1);
            removes[0] = remoteChainSelector;
            TokenPool.ChainUpdate[] memory noAdds = new TokenPool.ChainUpdate[](0);
            return CctActions._applyChainUpdates(poolAddress, removes, noAdds);
        }
        revert(
            "RemoveChain: pool version has no chain-removal dispatch branch; extend the switch here and the catalog in src/PoolVersions.sol"
        );
    }
}
