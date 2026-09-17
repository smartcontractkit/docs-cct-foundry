// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions, ISiloedLockReleaseV16} from "../../../src/actions/CctActions.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";

/// @notice Silos or unsilos remote chains on a SiloedLockReleaseTokenPool 1.6.x (`updateSiloDesignations`,
///         onlyOwner). Unsiloing moves the chain's balance into the shared bucket. A new silo starts at zero:
///         shared liquidity is not carried over, so fund it before inbound traffic from that chain arrives.
///
/// Environment Variables (at least one of the first two):
///   SILO_CHAINS      - Chains to silo, comma-separated names (AVALANCHE_FUJI) or selectors
///   UNSILO_CHAINS    - Chains to return to the shared bucket
///   SILO_REBALANCER  - Rebalancer for every newly siloed chain (required with SILO_CHAINS)
///
/// Usage:
///   SILO_CHAINS=AVALANCHE_FUJI SILO_REBALANCER=0x... \
///   forge script script/configure/siloed/UpdateSiloDesignations.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateSiloDesignations is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        address pool = _resolvePool(chainId);
        (, string memory full) = PoolVersion._requireSiloed(pool, PoolVersions.Op.SILOED_LIQUIDITY);

        uint64[] memory silo = _selectorsOf(vm.envOr("SILO_CHAINS", string("")));
        uint64[] memory unsilo = _selectorsOf(vm.envOr("UNSILO_CHAINS", string("")));
        require(silo.length + unsilo.length > 0, "Set SILO_CHAINS and/or UNSILO_CHAINS.");
        address rebalancer = silo.length > 0 ? vm.envAddress("SILO_REBALANCER") : address(0);

        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);
        // The pool's own reverts (InvalidChainSelector, ChainNotSiloed) do not say which rule failed.
        for (uint256 i = 0; i < unsilo.length; i++) {
            require(p.isSiloed(unsilo[i]), string.concat("Chain ", vm.toString(unsilo[i]), " is not siloed."));
        }
        ISiloedLockReleaseV16.SiloConfigUpdate[] memory adds = new ISiloedLockReleaseV16.SiloConfigUpdate[](silo.length);
        for (uint256 i = 0; i < silo.length; i++) {
            require(
                TokenPool(pool).isSupportedChain(silo[i]),
                string.concat("Chain ", vm.toString(silo[i]), " is not supported by the pool; add the lane first.")
            );
            require(!p.isSiloed(silo[i]), string.concat("Chain ", vm.toString(silo[i]), " is already siloed."));
            adds[i] = ISiloedLockReleaseV16.SiloConfigUpdate({remoteChainSelector: silo[i], rebalancer: rebalancer});
        }

        console.log("");
        console.log("========================================");
        console.log(unicode"🧱 Update Silo Designations");
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        for (uint256 i = 0; i < silo.length; i++) {
            console.log(string.concat("  silo   ", vm.toString(silo[i]), "  rebalancer=", vm.toString(rebalancer)));
        }
        for (uint256 i = 0; i < unsilo.length; i++) {
            console.log(
                string.concat(
                    "  unsilo ",
                    vm.toString(unsilo[i]),
                    "  moves ",
                    vm.toString(p.getAvailableTokens(unsilo[i])),
                    " to shared"
                )
            );
        }
        console.log("========================================");

        _executeCalls(CctActions._updateSiloDesignations(pool, unsilo, adds));
        _logOperationOutcome("update silo designations");
    }
}
