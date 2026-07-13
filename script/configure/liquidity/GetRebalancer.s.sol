// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {ILockReleaseV1Liquidity} from "../../../src/actions/CctActions.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Reads and displays the rebalancer of a v1.x LockRelease token pool (`getRebalancer`).
///
/// @dev A read-only script that DEGRADES, never reverts, on the version/type axis (like the other Get
///      scripts): on a 2.0.0 LockRelease pool the rebalancer model was replaced by an external lock box,
///      so it prints the lock box pointer instead; on a non-LockRelease pool it prints a clear note that
///      only LockRelease pools have a rebalancer. The `getRebalancer` capability range lives in the
///      catalog (`PoolVersions.Op.GET_REBALANCER`, 1.5.0 up to but not including 2.0.0).
///
/// Usage example:
///   forge script script/configure/liquidity/GetRebalancer.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetRebalancer is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"⚖️  Get Rebalancer (v1.x LockRelease)");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log("========================================");
        console.log("");

        // Read path: never revert on the type/version axis. tryResolve degrades to UNKNOWN + the raw
        // on-chain string on anything uncataloged, so we can still branch on the type prefix.
        (, PoolVersions.Version version, string memory full) = PoolVersion.tryResolve(tokenPoolAddress);
        string memory typePrefix = PoolVersion.typePrefixOf(full);
        bool isLockRelease = keccak256(bytes(typePrefix)) == keccak256(bytes("LockReleaseTokenPool"));

        if (!isLockRelease) {
            console.log(
                string.concat(
                    unicode"ℹ️  Not a LockRelease pool (on-chain \"",
                    bytes(full).length > 0 ? full : "unknown",
                    "\"). Only LockRelease pools have a rebalancer; BurnMint pools mint/burn and hold no liquidity."
                )
            );
        } else if (version >= PoolVersions.Version.V2_0_0) {
            console.log(
                unicode"ℹ️  This is a 2.0.0 LockRelease pool: the rebalancer model was replaced by an external lock box."
            );
            console.log(
                "   Liquidity is managed via operations/DepositToLockBox.s.sol / WithdrawFromLockBox.s.sol; see configure/GetLockBox.s.sol."
            );
            try LockReleaseTokenPool(tokenPoolAddress).getLockBox() returns (address lockBox) {
                console.log(string.concat("   LockBox: ", vm.toString(lockBox)));
            } catch {}
        } else {
            try ILockReleaseV1Liquidity(tokenPoolAddress).getRebalancer() returns (address rebalancer) {
                console.log(unicode"✅ Rebalancer:");
                console.log(string.concat("   ", vm.toString(rebalancer)));
                if (rebalancer == address(0)) {
                    console.log("   No rebalancer is set; set one with configure/liquidity/SetRebalancer.s.sol.");
                }
            } catch {
                console.log(
                    unicode"⚠️  getRebalancer() reverted; the pool may not expose the v1.x liquidity surface."
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
