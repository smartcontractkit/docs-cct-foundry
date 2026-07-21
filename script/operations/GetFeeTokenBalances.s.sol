// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {HelperUtils} from "../utils/HelperUtils.s.sol";
import {FeeTokenLogger} from "../utils/FeeTokenLogger.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";

/// @notice Displays the fee token balances currently held by a token pool.
///
/// @dev Read-only inspection script - no --broadcast flag required.
///      Run this before WithdrawFeeTokens to confirm which tokens have accrued fees
///      and to preview the filtered list that would be passed to the withdrawal.
///
/// @dev This function is only available on TokenPool v2.0 and later. Prior to v2.0, fee
///      configuration is managed by FeeQuoter and there is no pool-level fee balance.
///      If the pool does not support fee inspection, the script will revert with an
///      informative message.
///
/// @dev Callable by anyone - no signing or keystore required.
///
/// Environment Variables (required):
///   FEE_TOKENS - Comma-separated or JSON array of ERC20 token addresses to inspect.
///                Only ERC20 tokens are supported. Native tokens (ETH, AVAX, etc.) are
///                NOT supported - do not pass address(0).
///                CSV example:  "0xAAA...,0xBBB..."
///                JSON example: '["0xAAA...","0xBBB..."]'
///
/// Usage example (single token):
///   FEE_TOKENS="0xTokenA" \
///   forge script script/operations/GetFeeTokenBalances.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
///
/// Usage example (multiple tokens):
///   FEE_TOKENS="0xTokenA,0xTokenB" \
///   forge script script/operations/GetFeeTokenBalances.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetFeeTokenBalances is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Resolve chain ──────────────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        TokenPool tokenPool = TokenPool(tokenPoolAddress);
        address poolToken = address(tokenPool.getToken());

        // ── Parse fee token list ───────────────────────────────────────────
        // Accepts CSV ("0xA,0xB") or JSON array ("[\"0xA\",\"0xB\"]").
        // NOTE: Only ERC20 tokens are supported. Native tokens (ETH, AVAX, etc.)
        // are NOT supported - do not pass address(0).
        address[] memory feeTokens = HelperUtils._parseAddressArray(vm, vm.envOr("FEE_TOKENS", string("")), "");
        require(
            feeTokens.length > 0, "FEE_TOKENS is required: provide a CSV or JSON array of token addresses to inspect."
        );
        for (uint256 i = 0; i < feeTokens.length; i++) {
            require(
                feeTokens[i] != address(0),
                "FEE_TOKENS contains address(0). Native tokens (ETH/AVAX) are not supported. Provide ERC20 token addresses only."
            );
        }

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🔍 Get Fee Token Balances");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Inspect fee token balances"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Pool Token:   ", vm.toString(poolToken), " (for reference)"));
        console.log("");

        // ── Inspect balances ───────────────────────────────────────────────
        console.log("Fee Token Balances:");
        (uint256 nonZeroCount, address[] memory tokensToWithdraw) =
            FeeTokenLogger._logFeeTokenBalances(vm, tokenPoolAddress, feeTokens);

        // ── Summary ────────────────────────────────────────────────────────
        console.log("");
        if (nonZeroCount == 0) {
            console.log(unicode"ℹ️  No fee tokens have a non-zero balance in the pool. Nothing to withdraw.");
            console.log("========================================");
            console.log("");
            return;
        }

        console.log(
            string.concat(
                unicode"✅ ", vm.toString(nonZeroCount), " token(s) with non-zero balances are ready for withdrawal."
            )
        );
        console.log("");

        // Build a suggested WithdrawFeeTokens command from the non-zero tokens.
        string memory tokensCsv = vm.toString(tokensToWithdraw[0]);
        for (uint256 i = 1; i < tokensToWithdraw.length; i++) {
            tokensCsv = string.concat(tokensCsv, ",", vm.toString(tokensToWithdraw[i]));
        }
        console.log("To withdraw, run:");
        console.log(
            string.concat(
                "  FEE_TOKENS=\"",
                tokensCsv,
                "\" forge script script/operations/WithdrawFeeTokens.s.sol --rpc-url $",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_RPC_URL --account $KEYSTORE_NAME --broadcast"
            )
        );
        console.log("  (Add RECIPIENT=0x... to send to a different address; defaults to the broadcaster.)");

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("========================================");
        console.log("");
    }
}
