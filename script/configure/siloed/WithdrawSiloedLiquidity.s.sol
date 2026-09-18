// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions, ISiloedLockReleaseV16} from "../../../src/actions/CctActions.sol";

/// @notice Withdraws liquidity from one silo of a SiloedLockReleaseTokenPool 1.6.x to the silo rebalancer.
///         Inbound messages from that chain need this liquidity to release; draining it while messages are
///         in flight makes them fail until the silo is refunded.
///
/// Environment Variables:
///   DEST_CHAIN  - The siloed remote chain (name or selector), required
///   AMOUNT      - Amount in the token's smallest unit; defaults to everything available
///
/// Usage:
///   DEST_CHAIN=AVALANCHE_FUJI \
///   forge script script/configure/siloed/WithdrawSiloedLiquidity.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract WithdrawSiloedLiquidity is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        address pool = _resolvePool(block.chainid);
        (, string memory full) = PoolVersion._requireSiloed(pool, PoolVersions.Op.SILOED_LIQUIDITY);
        uint64 selector = _selectorOf(vm.envString("DEST_CHAIN"));

        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);
        require(p.isSiloed(selector), string.concat("Chain ", vm.toString(selector), " is not siloed."));
        uint256 available = p.getAvailableTokens(selector);
        uint256 amount = vm.envOr("AMOUNT", available);
        require(amount > 0, "Nothing to withdraw: the silo is empty.");
        require(
            amount <= available,
            string.concat(
                "InsufficientLiquidity: silo holds ", vm.toString(available), ", AMOUNT is ", vm.toString(amount)
            )
        );
        address actor = _executingAccount();
        address rebalancer = p.getChainRebalancer(selector);
        require(
            rebalancer == actor,
            string.concat(
                "NotRebalancer: the silo rebalancer is ",
                vm.toString(rebalancer),
                ", the executing account is ",
                vm.toString(actor),
                ". Set it with SetSiloRebalancer.s.sol."
            )
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🏧 Withdraw Siloed Liquidity");
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        console.log(string.concat("Silo:         ", vm.toString(selector)));
        console.log(string.concat("Available:    ", vm.toString(available)));
        console.log(string.concat("Amount:       ", vm.toString(amount), " -> ", vm.toString(actor)));
        console.log("========================================");

        _executeCalls(CctActions._withdrawSiloedLiquidity(pool, selector, amount));
        _logOperationOutcome(string.concat("withdraw ", vm.toString(amount), " from silo ", vm.toString(selector)));
    }
}
