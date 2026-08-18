// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {ChainHandlers} from "../../utils/ChainHandlers.s.sol";

/// @notice Removes a remote pool address from a TokenPool for a given remote chain.
///
/// @dev WARNING: All inflight transactions from the removed pool will be rejected after removal.
///      Ensure there are no inflight transactions from the pool before removing it to avoid
///      loss of funds.
///
/// Environment Variables (required):
///   DEST_CHAIN          - The remote chain where the pool to remove is deployed (e.g. MANTLE_SEPOLIA)
///   REMOTE_POOL_ADDRESS - The address of the remote pool to remove (EVM: 0x address;
///                         SVM: base58; Aptos: 0x hex)
///
/// Environment Variables (optional):
///   DEST_CHAIN_FAMILY   - Override destination family (default: from DEST_CHAIN config)
///   DEST_CHAIN_SELECTOR - Override destination selector (default: from DEST_CHAIN config)
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
        string memory remotePoolAddressRaw = vm.envString("REMOTE_POOL_ADDRESS");

        // ── Resolve selector/family from destination config (EVM and non-EVM) ─────
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
        string memory remoteChainDisplayName =
            bytes(destConfig.chainName).length > 0 ? destConfig.chainName : destChainName;

        require(
            ChainHandlers._validateChainAddress(remotePoolAddressRaw, destChainFamily),
            string.concat("Invalid ", destChainFamilyStr, " REMOTE_POOL_ADDRESS: ", remotePoolAddressRaw)
        );
        bytes memory remotePoolAddressEncoded =
            ChainHandlers._prepareChainAddressData(remotePoolAddressRaw, destChainFamily);

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

        _removeRemotePool(
            tokenPoolAddress,
            remotePoolAddressRaw,
            remotePoolAddressEncoded,
            remoteChainSelector,
            remoteChainDisplayName,
            destChainFamilyStr,
            destChainFamily
        );
    }

    /// @dev Everything after input resolution, starting with the version fence. Split from run()
    ///      so the fence-before-read ordering is testable with an injected pool address (env-based
    ///      pool resolution is process-global and cannot be exercised race-free under parallel
    ///      test suites).
    function _removeRemotePool(
        address tokenPoolAddress,
        string memory remotePoolAddressRaw,
        bytes memory remotePoolAddressEncoded,
        uint64 remoteChainSelector,
        string memory remoteChainDisplayName,
        string memory destChainFamilyStr,
        ChainHandlers.ChainFamily destChainFamily
    ) internal {
        uint256 sourceChainId = block.chainid;
        string memory sourceChainName = helperConfig.getChainName(sourceChainId);

        // Resolve and fence the pool version BEFORE any version-shaped read: a 1.5.0 pool must get
        // the named refusal here, not a raw selector revert from getRemotePools below.
        (PoolVersions.Version poolVersion,) = PoolVersion._resolve(tokenPoolAddress);
        // 1.5.0 holds exactly one remote pool per chain, reachable only via setRemotePool (replace),
        // so removing "just the pool" is not a standalone operation: dropping it necessarily drops
        // the lane. Point the operator at the whole-chain teardown instead of the generic refusal.
        require(
            poolVersion != PoolVersions.Version.V1_5_0,
            "removeRemotePool is not available on a 1.5.0 pool: 1.5.0 holds one remote pool per chain, so there is no standalone pool removal. To tear down the whole lane use script/configure/remote-chains/RemoveChain.s.sol; to swap the pool use AddRemotePool/ApplyChainUpdates."
        );
        PoolVersions._requireSupports(PoolVersions.Op.REMOVE_REMOTE_POOL, poolVersion, tokenPoolAddress);

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat("Remote chain not supported on this pool: ", remoteChainDisplayName)
        );

        require(
            tokenPool.isRemotePool(remoteChainSelector, remotePoolAddressEncoded),
            string.concat("Remote pool not configured for this chain: ", remotePoolAddressRaw)
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➖ Remove Remote Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", remoteChainDisplayName));
        console.log(string.concat("Remote Family:", " ", destChainFamilyStr));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Remove remote pool"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Pool to Remove: ", remotePoolAddressRaw));
        console.log("");
        console.log(unicode"⚠️  WARNING: All inflight transactions from this pool will be rejected after removal.");
        console.log("   Ensure there are no inflight transactions before proceeding.");
        console.log("");

        // ── Show current remote pools ──────────────────────────────────────
        bytes[] memory currentPools = tokenPool.getRemotePools(remoteChainSelector);
        console.log(string.concat("Current Remote Pools: ", vm.toString(currentPools.length)));
        for (uint256 i = 0; i < currentPools.length; i++) {
            console.log(
                string.concat(
                    "  [", vm.toString(i), "] ", ChainHandlers._formatAddress(destChainFamily, currentPools[i])
                )
            );
        }
        console.log("");

        console.log(string.concat("[Step 1] Removing remote pool on ", sourceChainName));

        _executeCalls(CctActions._removeRemotePool(tokenPoolAddress, remoteChainSelector, remotePoolAddressEncoded));

        _logOperationOutcome(
            string.concat("remove remote pool ", remotePoolAddressRaw, " for ", remoteChainDisplayName)
        );
        console.log("");
        console.log("========================================");
        _logOperationOutcome(string.concat("remove the remote pool on ", sourceChainName));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Remote Chain:    ", remoteChainDisplayName));
        console.log(string.concat("Removed Pool:    ", remotePoolAddressRaw));
        console.log(
            string.concat(
                "Token Pool:      ", helperConfig.getExplorerUrl(sourceChainId, "/address/", tokenPoolAddress)
            )
        );
        console.log("========================================");
        console.log("");
    }

    /// @dev Backward-compat overload kept for test harnesses and older internal call sites.
    ///      Interprets `remotePoolAddress` as an EVM address and delegates to the family-aware path.
    function _removeRemotePool(
        address tokenPoolAddress,
        address remotePoolAddress,
        uint64 remoteChainSelector,
        string memory,
        uint256 destChainId
    ) internal {
        _removeRemotePool(
            tokenPoolAddress,
            vm.toString(remotePoolAddress),
            abi.encode(remotePoolAddress),
            remoteChainSelector,
            helperConfig.getChainName(destChainId),
            "evm",
            ChainHandlers.ChainFamily.EVM
        );
    }
}
