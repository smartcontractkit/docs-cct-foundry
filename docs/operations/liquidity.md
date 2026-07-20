---
type: reference
---

# LockRelease liquidity

Manage the liquidity a LockRelease pool draws on to release tokens. The model differs by pool version:

- Versions 1.5.0, 1.5.1, and 1.6.1 hold the locked liquidity on the pool itself and manage it through a
  rebalancer.
- Version 2.0.0 holds no liquidity on the pool; an external `ERC20LockBox` does, so deposit and withdraw
  through the lock box.

Burn and mint pools have no liquidity to manage; they mint and burn. Scripts under
`script/configure/liquidity/` and `script/operations/`. Primitive pages:
[`GetRebalancer`](../primitives/liquidity/GetRebalancer.md),
[`SetRebalancer`](../primitives/liquidity/SetRebalancer.md),
[`ProvideLiquidity`](../primitives/liquidity/ProvideLiquidity.md),
[`WithdrawLiquidity`](../primitives/liquidity/WithdrawLiquidity.md),
[`DepositToLockBox`](../primitives/operations/DepositToLockBox.md),
[`WithdrawFromLockBox`](../primitives/operations/WithdrawFromLockBox.md).

## Rebalancer model (pool versions 1.5.0, 1.5.1, 1.6.1)

The rebalancer model has three roles:

- `setRebalancer`: the pool owner appoints the rebalancer.
- `provideLiquidity`: the rebalancer adds liquidity. The pool pulls the tokens with `transferFrom`, so
  the token is approved to the pool first and then the liquidity is provided, in one step.
- `withdrawLiquidity`: the rebalancer removes liquidity, which is transferred back to it. The pool
  reverts `InsufficientLiquidity` if its balance is below the requested amount.

Each script resolves the pool from the address registry (or the `TOKEN_POOL` / `{CHAIN}_TOKEN_POOL`
alias) and the token from the pool's `getToken()`. The write scripts refuse, with a clear message, before
broadcasting when the pool is the wrong type (not LockRelease) or the wrong version (2.0.0, which points
you at the lock box), or when the broadcaster is not the pool's rebalancer.

View the rebalancer:

```bash
forge script script/configure/liquidity/GetRebalancer.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

This read-only script degrades gracefully: on a 2.0.0 LockRelease pool it prints the lock box pointer
instead of a rebalancer, and on a non-LockRelease pool it explains that only LockRelease pools have a
rebalancer.

Set the rebalancer (broadcast as the pool owner):

```bash
REBALANCER=0xYourRebalancerAddress \
  forge script \
  script/configure/liquidity/SetRebalancer.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Provide liquidity (broadcast as the pool rebalancer; `AMOUNT` is in the token's smallest unit, wei):

```bash
AMOUNT=1000000000000000000 \
  forge script \
  script/configure/liquidity/ProvideLiquidity.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Withdraw liquidity (broadcast as the pool rebalancer):

```bash
AMOUNT=1000000000000000000 \
  forge script \
  script/configure/liquidity/WithdrawLiquidity.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var      | Script                                  | Required | Description                                                               |
| ------------ | --------------------------------------- | -------- | ------------------------------------------------------------------------- |
| `REBALANCER` | `SetRebalancer`                         | Yes      | Address to appoint as the pool's rebalancer.                              |
| `AMOUNT`     | `ProvideLiquidity`, `WithdrawLiquidity` | Yes      | Amount of liquidity to add or remove, in the token's smallest unit (wei). |

## Lock box model (pool version 2.0.0)

On a 2.0.0 LockRelease pool, an external `ERC20LockBox` holds the liquidity. Deposit and withdraw
directly against it. Both operations require the broadcaster to be an authorized caller on the lock box
(see [authorized callers](hooks-allowlist.md#manage-authorized-callers)).

Deposit tokens into an ERC20LockBox:

```bash
LOCK_BOX=0x... \
  forge script \
  script/operations/DepositToLockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Set `AMOUNT` to override the amount to deposit (defaults to `tokenAmountToTransfer` from
`script/input/token.json`).

Withdraw tokens from an ERC20LockBox:

```bash
LOCK_BOX=0x... \
  forge script \
  script/operations/WithdrawFromLockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

By default this withdraws the entire lock box balance. Set `AMOUNT` to withdraw a specific amount
instead. Set `RECIPIENT=0x...` to send withdrawn tokens to a different address (defaults to the
broadcaster).
