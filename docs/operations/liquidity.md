---
type: reference
---

# LockRelease liquidity

Manage the liquidity a LockRelease pool draws on to release tokens. The model differs by pool version:

- Versions 1.5.0, 1.5.1, and 1.6.1 hold the locked liquidity on the pool itself and manage it through a
  rebalancer.
- Version 2.0.0 holds no liquidity on the pool; an external `ERC20LockBox` does, so deposit and withdraw
  through the lock box.
- A `SiloedLockReleaseTokenPool` keeps liquidity per remote chain. See [Siloed pools](#siloed-pools).

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

<a id="siloed-pools"></a>

## Siloed pools

A `SiloedLockReleaseTokenPool` isolates liquidity per remote chain, so one chain's releases cannot drain
tokens locked for another. Scripts under `script/configure/siloed/`. Read the layout first:

```bash
forge script script/configure/siloed/GetSiloedPoolState.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

### 1.6.0 and 1.6.1: silos on the pool

The pool holds the tokens. A siloed chain has its own balance and rebalancer; every other chain draws on
one shared balance managed by the pool rebalancer (`SetRebalancer`, `ProvideLiquidity`,
`WithdrawLiquidity`).

| Script | Caller | Env |
| --- | --- | --- |
| `UpdateSiloDesignations` | owner | `SILO_CHAINS`, `SILO_REBALANCER`, `UNSILO_CHAINS` |
| `SetSiloRebalancer` | owner | `DEST_CHAIN`, `REBALANCER` |
| `ProvideSiloedLiquidity` | silo rebalancer | `DEST_CHAIN`, `AMOUNT` |
| `WithdrawSiloedLiquidity` | silo rebalancer | `DEST_CHAIN`, `AMOUNT` (default: all) |

- A new silo starts empty: shared liquidity is not moved into it. Unsiloing moves the silo's balance into
  the shared bucket.
- Inbound messages from a siloed chain release from that silo only. Withdrawing it while messages are in
  flight makes them fail until it is refunded.
- 1.6.0 validates rate limits like 1.5.x (`rate < capacity`, `rate > 0` when enabled); 1.6.1 does not.
  See the [behavior matrix](../reference/pool-behavior-matrix.md).

### 2.0.0: one lock box per silo

The pool holds nothing. `configureLockBoxes` maps each remote chain to an `ERC20LockBox`; chains that share
a box share liquidity. Build it in this order, before wiring any lane:

```bash
make deploy-siloed-pool CHAIN=ethereum-testnet-sepolia KEYSTORE_NAME=<ks>
make deploy-lockbox CHAIN=ethereum-testnet-sepolia KEYSTORE_NAME=<ks> SILO=fuji    # once per silo
LOCK_BOX=<box> ADD_ADDRESSES=<pool> forge script script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol ...
LOCK_BOXES=AVALANCHE_TESTNET_FUJI=<box>,ETHEREUM_TESTNET_SEPOLIA_BASE_1=<box2> \
  forge script script/configure/siloed/ConfigureLockBoxes.s.sol ...
```

- `SILO=<label>` records the box as `{symbol}_LockBox_{label}` and leaves `active.lockBox` alone, so
  per-box scripts need `LOCK_BOX=` explicitly.
- A supported chain without a box reverts every transfer. `ApplyChainUpdates` refuses to add such a lane
  (Safe mode warns instead, since the batch may map it).
- `configureLockBoxes` never removes an entry, and does not check that the pool may use the box;
  `ConfigureLockBoxes` refuses when it may not.
- **A silo isolates a chain only while that chain has no DIRECT lane to a differently-boxed sibling.** Two
  remotes served by DIFFERENT boxes must not have a lane to each other: supply moves while liquidity does
  not, so one box ends up holding tokens no supply can claim and the other cannot cover its own chain.
  Routing between them THROUGH the hub is fine - that path releases from one box and locks into the other.
  Chains that should trade directly belong on the SAME box. `ApplyChainUpdates` refuses to wire a lane
  whose peer also runs a lock-release pool (`ACK_LOCK_AND_LOCK=true` overrides), and `make doctor` fails
  such a pair when it can read both peers' project stores, saying so when it cannot; see
  [the gotcha](../gotchas/index.md#silos-need-no-second-route) for the measured drift.
- `make doctor` fails a supported chain with no box, a box that does not authorize the pool, or a box for
  another token, and warns about a box still mapped to a removed chain. `snapshot-chain` records the boxes
  under `roles.lockboxes`, and `roles-check` audits each one.
- Every authorized caller on a box can withdraw its whole balance. Authorize operators, not users.
- The v2 transfer fee stays on the pool, not in the box (`WithdrawFeeTokens`).
- A 1.6.x pool cannot be pointed at a 2.0 box, and 1.6.2+ lock boxes have a different interface.
  Migrating from 1.6.x moves the tokens: see [migrate a Siloed pool](../guides/migrate-siloed-pool.md).
