// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {HelperConfig} from "../../HelperConfig.s.sol";
import {ILockReleaseV1Liquidity} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @title LiquidityBase
/// @notice Shared base for the v1.x LockRelease liquidity write scripts (SetRebalancer, ProvideLiquidity,
///         WithdrawLiquidity). Holds the one pool-resolution ladder and the two rebalancer/liquidity
///         precondition checks, each surfaced as a NAMED, self-explaining message (never a raw on-chain
///         revert) and each backed by a `internal pure` message builder so tests can pin the wording
///         byte-exact and a harness can drive the check with an injected mock pool.
abstract contract LiquidityBase is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev Resolves the pool the same way every other configure script does: the `TOKEN_POOL` inline
    ///      alias / `{CHAIN}_TOKEN_POOL` / registry `active.tokenPool`, via `getDeployedTokenPool`.
    function _resolvePool(uint256 chainId) internal view returns (address pool) {
        pool = helperConfig.getDeployedTokenPool(chainId);
        require(
            pool != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );
    }

    /// @dev Refuses, by name, when the broadcaster is not the pool's rebalancer - the only account the
    ///      v1.x pool lets call `provideLiquidity` / `withdrawLiquidity`. Fails BEFORE any broadcast so
    ///      the user sees the fix, not a bare `msg.sender != s_rebalancer` revert from the pool.
    function _requireRebalancer(address pool, address broadcasterAddr, string memory op) internal view {
        address rebalancer = ILockReleaseV1Liquidity(pool).getRebalancer();
        require(rebalancer == broadcasterAddr, _rebalancerMismatchMessage(op, rebalancer, broadcasterAddr));
    }

    /// @dev The rebalancer-mismatch message. `internal pure` so tests pin it byte-exact.
    function _rebalancerMismatchMessage(string memory op, address rebalancer, address broadcasterAddr)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "NotRebalancer: ",
            op,
            " can only be called by the pool's rebalancer (",
            vm.toString(rebalancer),
            "), but the broadcaster is ",
            vm.toString(broadcasterAddr),
            ". Set it first with configure/liquidity/SetRebalancer.s.sol (REBALANCER=<addr>, run as the pool owner)."
        );
    }

    /// @dev Refuses, by name, when the pool holds less than the requested withdrawal - the v1 pool would
    ///      otherwise revert its own `InsufficientLiquidity`. Surfacing the balance and the amount up
    ///      front turns that opaque revert into an actionable message.
    function _requireSufficientLiquidity(address pool, uint256 balance, uint256 amount) internal pure {
        require(balance >= amount, _insufficientLiquidityMessage(pool, balance, amount));
    }

    /// @dev The insufficient-liquidity message. `internal pure` so tests pin it byte-exact.
    function _insufficientLiquidityMessage(address pool, uint256 balance, uint256 amount)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "InsufficientLiquidity: pool ",
            vm.toString(pool),
            " holds ",
            vm.toString(balance),
            " but withdrawLiquidity(",
            vm.toString(amount),
            ") was requested; the v1 pool reverts InsufficientLiquidity when its balance is below the amount.",
            " Provide liquidity first or lower AMOUNT."
        );
    }
}
