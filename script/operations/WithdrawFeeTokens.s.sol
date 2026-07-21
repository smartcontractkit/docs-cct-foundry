// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {HelperUtils} from "../utils/HelperUtils.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {FeeTokenLogger} from "../utils/FeeTokenLogger.s.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/// @notice Withdraws accrued fee token balances from a token pool to a specified recipient.
///
/// @dev This function is only available on TokenPool v2.0 and later. Prior to v2.0, fee configuration
///      is managed by FeeQuoter and configured directly by the Chainlink team upon token issuer request.
///      If the pool does not support this function, the script will revert with an informative message.
///
/// @dev Callable only by the pool owner or the designated fee admin.
///
/// @dev The pool token address is printed for reference, but this script makes no assumptions
///      about which ERC20 tokens have accumulated as fees. You must explicitly supply the token(s)
///      to withdraw via FEE_TOKENS.
///
/// Environment Variables (required):
///   FEE_TOKENS - Comma-separated or JSON array of ERC20 token addresses to withdraw.
///                Only ERC20 tokens are supported. Native tokens (ETH, AVAX, etc.) are
///                NOT supported - do not pass address(0).
///                CSV example:  "0xAAA...,0xBBB..."
///                JSON example: '["0xAAA...","0xBBB..."]'
///
/// Environment Variables (optional):
///   RECIPIENT  - The address to receive the withdrawn fee tokens (defaults to the broadcaster)
///
/// Usage example (single fee token):
///   FEE_TOKENS="0xTokenThatAccruedFees" \
///   forge script script/operations/WithdrawFeeTokens.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (multiple fee tokens, custom recipient):
///   RECIPIENT=0xYourAddress \
///   FEE_TOKENS="0xFirstFeeToken,0xSecondFeeToken" \
///   forge script script/operations/WithdrawFeeTokens.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract WithdrawFeeTokens is EoaExecutor {
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
        // No assumptions are made about which token(s) have accrued as fees.
        // The caller must supply the exact token address(es) to withdraw.
        // Accepts CSV ("0xA,0xB") or JSON array ("[\"0xA\",\"0xB\"]").
        // NOTE: Only ERC20 tokens are supported. Native tokens (ETH, AVAX, etc.)
        // are NOT supported by withdrawFeeTokens() - do not pass address(0).
        address[] memory feeTokens = HelperUtils._parseAddressArray(vm, vm.envOr("FEE_TOKENS", string("")), "");
        require(
            feeTokens.length > 0, "FEE_TOKENS is required: provide a CSV or JSON array of token addresses to withdraw."
        );
        for (uint256 i = 0; i < feeTokens.length; i++) {
            require(
                feeTokens[i] != address(0),
                "FEE_TOKENS contains address(0). Native tokens (ETH/AVAX) are not supported by withdrawFeeTokens(). Provide ERC20 token addresses only."
            );
        }

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"💸 Withdraw Fee Tokens");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Withdraw fee tokens"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Pool Token:   ", vm.toString(poolToken), " (for reference)"));
        console.log("");
        console.log("Tokens to Withdraw:");
        (uint256 nonZeroCount, address[] memory tokensToWithdraw) =
            FeeTokenLogger._logFeeTokenBalances(vm, tokenPoolAddress, feeTokens);
        if (nonZeroCount == 0) {
            console.log("");
            console.log(unicode"⚠️  No fee tokens have a non-zero balance in the pool. Nothing to withdraw.");
            console.log("========================================");
            console.log("");
            return;
        }
        console.log("");

        // ── Broadcast ─────────────────────────────────────────────────────
        console.log(string.concat("[Step 1] Withdrawing fee tokens on ", chainName));

        // RECIPIENT defaults to the broadcaster (the account signing the transaction).
        address recipient = vm.envOr("RECIPIENT", _broadcaster());
        console.log(string.concat("Recipient:    ", vm.toString(recipient)));

        // withdrawFeeTokens() was introduced in TokenPool v2.0.
        // On v1 pools, fee configuration is handled by FeeQuoter and there is no
        // pool-level fee withdrawal mechanism - fees are not accrued by the pool contract.
        _executeCalls(CctActions._withdrawFeeTokens(tokenPoolAddress, tokensToWithdraw, recipient));
        console.log(unicode"✅ Fee tokens withdrawn successfully!");

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Withdrawal complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Recipient:    ", vm.toString(recipient)));
        console.log(string.concat("Recipient:    ", helperConfig.getExplorerUrl(chainId, "/address/", recipient)));
        console.log("========================================");
        console.log("");
    }
}
