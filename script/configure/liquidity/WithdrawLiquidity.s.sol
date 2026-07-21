// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {LiquidityBase} from "./LiquidityBase.s.sol";
import {CctActions, ILockReleaseV1Liquidity} from "../../../src/actions/CctActions.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Withdraws lock/release liquidity from a v1.x LockRelease token pool (`withdrawLiquidity`). The
///         tokens transfer OUT to the caller. The broadcaster MUST be the pool's rebalancer, and the pool
///         must hold at least `AMOUNT` (else the pool reverts `InsufficientLiquidity`).
///
/// @dev v1.x LockRelease pools ONLY. A 2.0.0 LockRelease pool holds no liquidity (it uses an external lock
///      box: `operations/WithdrawFromLockBox.s.sol`), and a non-LockRelease pool has no liquidity at all;
///      both are refused by the shared two-dimensional fence before any broadcast.
///
/// Environment Variables (required):
///   AMOUNT  - The amount of liquidity to withdraw, in the token's smallest unit (wei).
///
/// Broadcasts as the pool REBALANCER.
///
/// Usage example:
///   AMOUNT=1000000000000000000 \
///   forge script script/configure/liquidity/WithdrawLiquidity.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract WithdrawLiquidity is LiquidityBase {
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        require(amount > 0, "Invalid amount. Set AMOUNT to a non-zero value in the token's smallest unit (wei).");

        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        address tokenPoolAddress = _resolvePool(chainId);

        (PoolVersions.Version poolVersion, string memory typeAndVersion) =
            PoolVersion._requireLockReleaseLiquidity(tokenPoolAddress);

        address tokenAddress = address(ILockReleaseV1Liquidity(tokenPoolAddress).getToken());
        address broadcasterAddr = _broadcaster();
        // The pool only lets its rebalancer withdraw - refuse by name before broadcasting.
        _requireRebalancer(tokenPoolAddress, broadcasterAddr, "withdrawLiquidity");

        // Surface the InsufficientLiquidity precondition up front (the pool reverts it when balance < amount).
        uint256 poolBalance = IERC20(tokenAddress).balanceOf(tokenPoolAddress);
        _requireSufficientLiquidity(tokenPoolAddress, poolBalance, amount);

        console.log("");
        console.log("========================================");
        console.log(unicode"💸 Withdraw Liquidity (v1.x LockRelease)");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Pool Version: ", PoolVersions._toString(poolVersion), " (", typeAndVersion, ")"));
        console.log(string.concat("Token:        ", vm.toString(tokenAddress)));
        console.log(string.concat("Rebalancer:   ", vm.toString(broadcasterAddr)));
        console.log(string.concat("Pool Balance: ", vm.toString(poolBalance)));
        console.log(string.concat("Amount:       ", vm.toString(amount)));
        console.log("========================================");
        console.log("");

        console.log(string.concat("[Step 1] Withdrawing ", vm.toString(amount), " tokens of liquidity"));
        _executeCalls(CctActions._withdrawLiquidity(tokenPoolAddress, amount));
        console.log(unicode"✅ Liquidity withdrawn successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Pool Liquidity: ", vm.toString(IERC20(tokenAddress).balanceOf(tokenPoolAddress))));
        console.log(string.concat("Rebalancer Balance: ", vm.toString(IERC20(tokenAddress).balanceOf(broadcasterAddr))));
        console.log(
            string.concat("Token Pool:     ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
