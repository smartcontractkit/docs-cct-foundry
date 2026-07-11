// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Removes a remote pool address from a TokenPool for a given remote chain.
///
/// @dev WARNING: All inflight transactions from the removed pool will be rejected after removal.
///      Ensure there are no inflight transactions from the pool before removing it to avoid
///      loss of funds.
///
/// Environment Variables (required):
///   DEST_CHAIN          - The remote chain where the pool to remove is deployed (e.g. MANTLE_SEPOLIA)
///   REMOTE_POOL_ADDRESS - The address of the remote pool to remove
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   REMOTE_POOL_ADDRESS=0xOldRemotePoolAddress \
///   forge script script/configure/remote-pools/RemoveRemotePool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract RemoveRemotePool is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        address remotePoolAddress = vm.envAddress("REMOTE_POOL_ADDRESS");

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

        _removeRemotePool(tokenPoolAddress, remotePoolAddress, remoteChainSelector, destChainName, destChainId);
    }

    /// @dev Everything after input resolution, starting with the version fence. Split from run()
    ///      so the fence-before-read ordering is testable with an injected pool address (env-based
    ///      pool resolution is process-global and cannot be exercised race-free under parallel
    ///      test suites).
    function _removeRemotePool(
        address tokenPoolAddress,
        address remotePoolAddress,
        uint64 remoteChainSelector,
        string memory destChainName,
        uint256 destChainId
    ) internal {
        uint256 sourceChainId = block.chainid;
        string memory sourceChainName = helperConfig.getChainName(sourceChainId);

        // Resolve and fence the pool version BEFORE any version-shaped read: a 1.5.0 pool must get
        // the named refusal here, not a raw selector revert from getRemotePools below.
        (PoolVersions.Version poolVersion,) = PoolVersion.resolve(tokenPoolAddress);
        PoolVersions.requireSupports(PoolVersions.Op.REMOVE_REMOTE_POOL, poolVersion, tokenPoolAddress);

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat("Remote chain not supported on this pool: ", destChainName)
        );

        require(
            tokenPool.isRemotePool(remoteChainSelector, abi.encode(remotePoolAddress)),
            string.concat("Remote pool not configured for this chain: ", vm.toString(remotePoolAddress))
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➖ Remove Remote Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Remove remote pool"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Pool to Remove: ", vm.toString(remotePoolAddress)));
        console.log("");
        console.log(unicode"⚠️  WARNING: All inflight transactions from this pool will be rejected after removal.");
        console.log("   Ensure there are no inflight transactions before proceeding.");
        console.log("");

        // ── Show current remote pools ──────────────────────────────────────
        bytes[] memory currentPools = tokenPool.getRemotePools(remoteChainSelector);
        console.log(string.concat("Current Remote Pools: ", vm.toString(currentPools.length)));
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

        console.log(string.concat("[Step 1] Removing remote pool on ", sourceChainName));

        executeCalls(CctActions.removeRemotePool(tokenPoolAddress, remoteChainSelector, abi.encode(remotePoolAddress)));

        console.log(unicode"✅ Remote pool removed successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", sourceChainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Remote Chain:    ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Removed Pool:    ", vm.toString(remotePoolAddress)));
        console.log(
            string.concat(
                "Token Pool:      ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }
}
