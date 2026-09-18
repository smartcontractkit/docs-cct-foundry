// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions, ISiloedLockReleaseV16} from "../../../src/actions/CctActions.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";

/// @notice Adds liquidity to one silo of a SiloedLockReleaseTokenPool 1.6.x: `approve` then
///         `provideSiloedLiquidity`, as the silo's rebalancer.
///
/// Environment Variables (required):
///   DEST_CHAIN  - The siloed remote chain (name or selector)
///   AMOUNT      - Amount in the token's smallest unit
///
/// Usage:
///   DEST_CHAIN=AVALANCHE_FUJI AMOUNT=100000000 \
///   forge script script/configure/siloed/ProvideSiloedLiquidity.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract ProvideSiloedLiquidity is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        address pool = _resolvePool(block.chainid);
        (, string memory full) = PoolVersion._requireSiloed(pool, PoolVersions.Op.SILOED_LIQUIDITY);
        uint64 selector = _selectorOf(vm.envString("DEST_CHAIN"));
        uint256 amount = vm.envUint("AMOUNT");
        require(amount > 0, "AMOUNT must be non-zero.");

        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);
        require(p.isSiloed(selector), string.concat("Chain ", vm.toString(selector), " is not siloed."));
        address token = address(TokenPool(pool).getToken());
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
        uint256 held = IERC20(token).balanceOf(actor);
        require(
            held >= amount,
            string.concat("Insufficient token balance: ", vm.toString(held), " < AMOUNT ", vm.toString(amount))
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"💧 Provide Siloed Liquidity");
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        console.log(string.concat("Silo:         ", vm.toString(selector)));
        console.log(string.concat("Available:    ", vm.toString(p.getAvailableTokens(selector))));
        console.log(string.concat("Amount:       ", vm.toString(amount)));
        console.log("========================================");

        _executeCalls(CctActions._provideSiloedLiquidity(pool, token, selector, amount));
        _logOperationOutcome(string.concat("provide ", vm.toString(amount), " to silo ", vm.toString(selector)));
    }
}
