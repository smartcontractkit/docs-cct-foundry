// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions, ISiloedLockReleaseV16} from "../../../src/actions/CctActions.sol";

/// @notice Sets the rebalancer of one silo on a SiloedLockReleaseTokenPool 1.6.x (onlyOwner). Only that
///         account can provide or withdraw the silo's liquidity. For the shared bucket use
///         configure/liquidity/SetRebalancer.s.sol.
///
/// Environment Variables (required):
///   DEST_CHAIN  - The siloed remote chain (name or selector)
///   REBALANCER  - The new silo rebalancer
///
/// Usage:
///   DEST_CHAIN=AVALANCHE_FUJI REBALANCER=0x... \
///   forge script script/configure/siloed/SetSiloRebalancer.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetSiloRebalancer is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        address pool = _resolvePool(block.chainid);
        (, string memory full) = PoolVersion._requireSiloed(pool, PoolVersions.Op.SILOED_LIQUIDITY);
        uint64 selector = _selectorOf(vm.envString("DEST_CHAIN"));
        address rebalancer = vm.envAddress("REBALANCER");

        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);
        require(
            p.isSiloed(selector),
            string.concat("Chain ", vm.toString(selector), " is not siloed; its rebalancer is the pool rebalancer.")
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"⚖️  Set Silo Rebalancer");
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        console.log(string.concat("Silo:         ", vm.toString(selector)));
        console.log(string.concat("Current:      ", vm.toString(p.getChainRebalancer(selector))));
        console.log(string.concat("New:          ", vm.toString(rebalancer)));
        console.log("========================================");

        _executeCalls(CctActions._setSiloRebalancer(pool, selector, rebalancer));
        _logOperationOutcome(string.concat("set the silo rebalancer to ", vm.toString(rebalancer)));
    }
}
