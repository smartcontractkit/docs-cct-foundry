// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FeeTokenLogger
/// @notice Shared utility for inspecting and logging fee token balances held by a token pool.
/// @dev Used by both GetFeeTokenBalances (read-only inspection) and WithdrawFeeTokens
///      (pre-withdrawal summary) so that both scripts produce identical formatted output.
library FeeTokenLogger {
    /// @notice Logs each fee token's balance in the pool and returns a filtered list of tokens
    ///         that have a non-zero balance (i.e. are eligible for withdrawal).
    ///
    /// @dev Balances are cached in memory on the first pass to avoid a second round-trip of
    ///      external calls when building the filtered array.
    ///
    /// @param vm           The forge Vm instance, used for address/uint-to-string formatting.
    /// @param poolAddress  The token pool address whose ERC20 balances are inspected.
    /// @param feeTokens    The ERC20 token addresses to inspect. Must not contain address(0).
    ///
    /// @return nonZeroCount     Number of tokens whose pool balance is greater than zero.
    /// @return tokensToWithdraw Filtered array containing only the tokens with a non-zero
    ///                          balance, preserving the original relative order.
    function _logFeeTokenBalances(Vm vm, address poolAddress, address[] memory feeTokens)
        internal
        view
        returns (uint256 nonZeroCount, address[] memory tokensToWithdraw)
    {
        // ── Cache balances ─────────────────────────────────────────────────
        // Fetch and store each balance once so the filter pass below can
        // reuse the cached values without making additional external calls.
        uint256[] memory balances = new uint256[](feeTokens.length);
        nonZeroCount = 0;

        for (uint256 i = 0; i < feeTokens.length; i++) {
            balances[i] = IERC20(feeTokens[i]).balanceOf(poolAddress);
            if (balances[i] == 0) {
                console.log(
                    string.concat(
                        unicode"  [",
                        vm.toString(i),
                        unicode"] ",
                        vm.toString(feeTokens[i]),
                        unicode"  →  balance: 0 ⚠️  (skipping)"
                    )
                );
            } else {
                console.log(
                    string.concat(
                        unicode"  [",
                        vm.toString(i),
                        unicode"] ",
                        vm.toString(feeTokens[i]),
                        unicode"  →  balance: ",
                        vm.toString(balances[i])
                    )
                );
                nonZeroCount++;
            }
        }

        // ── Build filtered array ───────────────────────────────────────────
        tokensToWithdraw = new address[](nonZeroCount);
        uint256 j = 0;
        for (uint256 i = 0; i < feeTokens.length; i++) {
            if (balances[i] > 0) {
                tokensToWithdraw[j++] = feeTokens[i];
            }
        }
    }
}
