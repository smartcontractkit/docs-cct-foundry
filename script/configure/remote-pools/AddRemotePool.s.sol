// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Adds a remote pool address to a TokenPool for a given remote chain.
///
/// @dev Use this when a pool has been upgraded on a remote chain. The old pool address is kept
///      to allow inflight messages to complete. Multiple remote pool addresses can be active
///      at the same time for the same chain selector.
/// @dev The remote chain must already be supported (added via ApplyChainUpdates) before calling this.
///
/// Environment Variables (required):
///   DEST_CHAIN         - The remote chain where the new pool was deployed (e.g. MANTLE_SEPOLIA)
///   REMOTE_POOL_ADDRESS - The address of the new remote pool to add
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   REMOTE_POOL_ADDRESS=0xNewRemotePoolAddress \
///   forge script script/configure/remote-pools/AddRemotePool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract AddRemotePool is EoaExecutor {
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

        _addRemotePool(tokenPoolAddress, remotePoolAddress, remoteChainSelector, destChainName, destChainId);
    }

    /// @dev Everything after input resolution, starting with the version fence. Split from run()
    ///      so the fence-before-read ordering is testable with an injected pool address (env-based
    ///      pool resolution is process-global and cannot be exercised race-free under parallel
    ///      test suites).
    function _addRemotePool(
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
        PoolVersions.requireSupports(PoolVersions.Op.ADD_REMOTE_POOL, poolVersion, tokenPoolAddress);

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat(
                "Remote chain not supported. Run ApplyChainUpdates first to add ",
                destChainName,
                " as a supported chain."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➕ Add Remote Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Add remote pool"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("New Remote Pool: ", vm.toString(remotePoolAddress)));
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

        console.log(string.concat("[Step 1] Adding remote pool on ", sourceChainName));

        executeCalls(CctActions.addRemotePool(tokenPoolAddress, remoteChainSelector, abi.encode(remotePoolAddress)));

        console.log(unicode"✅ Remote pool added successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", sourceChainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Remote Chain:    ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Added Pool:      ", vm.toString(remotePoolAddress)));
        console.log(
            string.concat(
                "Token Pool:      ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }
}
