// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {LiquidityBase} from "./LiquidityBase.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Sets the rebalancer on a v1.x LockRelease token pool (`setRebalancer`, onlyOwner). The
///         rebalancer is the one account allowed to provide/withdraw the pool's lock/release liquidity.
///
/// @dev v1.x LockRelease pools ONLY (1.5.0 / 1.5.1 / 1.6.1). On a 2.0.0 LockRelease pool liquidity moved
///      to an external lock box, so the script refuses with a pointer at the lock box scripts; on a
///      non-LockRelease (e.g. BurnMint) pool it refuses by type. Both refusals come from the shared
///      two-dimensional fence (`PoolVersion._requireLockReleaseLiquidity`), before any broadcast.
///
/// Environment Variables (required):
///   REBALANCER  - The address to set as the pool's rebalancer.
///
/// Broadcasts as the pool OWNER.
///
/// Usage example:
///   REBALANCER=0xYourRebalancerAddress \
///   forge script script/configure/liquidity/SetRebalancer.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetRebalancer is LiquidityBase {
    function run() external {
        address rebalancer = vm.envAddress("REBALANCER");

        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        address tokenPoolAddress = _resolvePool(chainId);

        // Two-dimensional fence (type must be LockRelease; version must be < 2.0.0), before any read/write.
        (PoolVersions.Version poolVersion, string memory typeAndVersion) =
            PoolVersion._requireLockReleaseLiquidity(tokenPoolAddress);

        console.log("");
        console.log("========================================");
        console.log(unicode"⚖️  Set Rebalancer (v1.x LockRelease)");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Pool Version: ", PoolVersions._toString(poolVersion), " (", typeAndVersion, ")"));
        console.log(string.concat("New Rebalancer: ", vm.toString(rebalancer)));
        console.log("========================================");
        console.log("");

        console.log(string.concat("[Step 1] Setting rebalancer on ", chainName));
        _executeCalls(CctActions._setRebalancer(tokenPoolAddress, rebalancer));
        console.log(unicode"✅ Rebalancer set successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Configuration Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Rebalancer:   ", vm.toString(rebalancer)));
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
