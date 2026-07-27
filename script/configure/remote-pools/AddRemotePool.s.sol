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
import {AddressEncoding} from "../../utils/AddressEncoding.s.sol";

/// @notice Adds a remote pool address to a TokenPool for a given remote chain.
///
/// @dev Use this when a pool has been upgraded on a remote chain. The old pool address is kept
///      to allow inflight messages to complete. Multiple remote pool addresses can be active
///      at the same time for the same chain selector.
/// @dev The remote chain must already be supported (added via ApplyChainUpdates) before calling this.
///
/// Environment Variables (required):
///   DEST_CHAIN         - The remote chain where the new pool was deployed (e.g. MANTLE_SEPOLIA)
///   REMOTE_POOL_ADDRESS - The address of the new remote pool to add (EVM: 0x address;
///                         SVM: base58; Aptos: 0x hex)
///
/// Environment Variables (optional):
///   DEST_CHAIN_FAMILY   - Override destination family (default: from DEST_CHAIN config)
///   DEST_CHAIN_SELECTOR - Override destination selector (default: from DEST_CHAIN config)
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

        _addRemotePool(
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
    function _addRemotePool(
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
        PoolVersions._requireSupports(PoolVersions.Op.ADD_REMOTE_POOL, poolVersion, tokenPoolAddress);

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(remoteChainSelector),
            string.concat(
                "Remote chain not supported. Run ApplyChainUpdates first to add ",
                remoteChainDisplayName,
                " as a supported chain."
            )
        );

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"➕ Add Remote Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", sourceChainName));
        console.log(string.concat("Remote Chain: ", remoteChainDisplayName));
        console.log(string.concat("Remote Family:", " ", destChainFamilyStr));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Add remote pool"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("New Remote Pool: ", remotePoolAddressRaw));
        console.log("");

        // ── Show current remote pools ──────────────────────────────────────
        bytes[] memory currentPools = tokenPool.getRemotePools(remoteChainSelector);
        console.log(string.concat("Current Remote Pools: ", vm.toString(currentPools.length)));
        for (uint256 i = 0; i < currentPools.length; i++) {
            if (
                destChainFamily == ChainHandlers.ChainFamily.EVM
                    && AddressEncoding._isAbiEncodedAddress(currentPools[i])
            ) {
                console.log(
                    string.concat("  [", vm.toString(i), "] ", vm.toString(abi.decode(currentPools[i], (address))))
                );
            } else {
                console.log(string.concat("  [", vm.toString(i), "] (raw) ", vm.toString(currentPools[i])));
            }
        }
        console.log("");

        console.log(string.concat("[Step 1] Adding remote pool on ", sourceChainName));

        _executeCalls(CctActions._addRemotePool(tokenPoolAddress, remoteChainSelector, remotePoolAddressEncoded));

        console.log(unicode"✅ Remote pool added successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", sourceChainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:      ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Remote Chain:    ", remoteChainDisplayName));
        console.log(string.concat("Added Pool:      ", remotePoolAddressRaw));
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
    function _addRemotePool(
        address tokenPoolAddress,
        address remotePoolAddress,
        uint64 remoteChainSelector,
        string memory,
        uint256 destChainId
    ) internal {
        _addRemotePool(
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
