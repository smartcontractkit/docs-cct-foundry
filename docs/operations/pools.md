---
type: reference
---

# Token pool deployment

> After applying a change here, sync your declared source of truth (the project store) and reconcile it
> against live with `make doctor CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).

Deploy the token pool that CCIP burns, mints, locks, or releases through. Scripts under
`script/deploy/`. Primitive pages:
[`DeployBurnMintTokenPool`](../primitives/deploy/DeployBurnMintTokenPool.md),
[`DeployLockReleaseTokenPool`](../primitives/deploy/DeployLockReleaseTokenPool.md),
[`DeployERC20LockBox`](../primitives/deploy/DeployERC20LockBox.md),
[`GetLockBox`](../primitives/configure/GetLockBox.md). For the per-version support matrix see
[Pool versions](../pool-versions.md).

A broadcast deploy records the pool (and lockbox) address in the project store, so later scripts
resolve it automatically with no `export`. See [Deployed addresses](../deployed-addresses.md). To
override for one session, `export ETHEREUM_SEPOLIA_TOKEN_POOL=0x...` or pass `TOKEN_POOL=0x...` inline.

## Burn and mint pool

Tokens are burned on the source chain and minted on the destination.

Golden path:

```bash
make deploy-pool CHAIN=ethereum-testnet-sepolia VERIFY=1
make deploy-pool CHAIN=ethereum-testnet-sepolia-mantle-1 VERIFY=1
```

Raw `forge script`:

```bash
# Deploy pool on Ethereum Sepolia
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# Deploy pool on Mantle Sepolia
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

The address is saved to `history/token-pools/{selectorName}/{timestamp}-{SYMBOL}-BurnMintTokenPool.json`
(keys `{CHAIN_NAME_IDENTIFIER}_TOKEN_POOL` and `{CHAIN_NAME_IDENTIFIER}_TOKEN`).

Set `POOL_HOOKS=0x...` to attach an `AdvancedPoolHooks` contract at deploy time. Set `DECIMALS=<n>` if
your token does not implement the optional `decimals()` ERC20 function; the script falls back to this
value and fails if neither is available. The script also attempts `grantMintAndBurnRoles` on the token
to grant the pool mint and burn rights; if the token does not implement it, the script prints
instructions to grant the roles manually.

## Lock and release pool

Use this when you do not have burn and mint rights on the source chain token (for example, it was
issued by a third party). The `LockReleaseTokenPool` requires an `ERC20LockBox` at deploy time, and the
lockbox must authorize the pool before it can deposit or withdraw tokens. The deployment order is always
lockbox, then pool, then authorize the pool on the lockbox.

`LOCK_BOX` is required and must be the address of a deployed `ERC20LockBox` for the token. Set
`POOL_HOOKS=0x...` to attach an already-deployed `AdvancedPoolHooks` contract. Set `DECIMALS=<n>` if
your token does not implement `decimals()`. When deploying the lockbox, optionally set
`AUTHORIZED_CALLERS` (CSV or JSON array) to authorize addresses immediately, useful for letting the
deployer or token issuer deposit and withdraw initial liquidity.

The golden-path targets `make deploy-lockbox CHAIN=<name> VERIFY=1` and
`make deploy-lockrelease-pool CHAIN=<name> VERIFY=1` resolve the token and lock box from the registry;
the raw sequences below spell out the addresses explicitly.

### Pattern A: lock on source, mint on destination

The token was originally issued on one chain; you control the token on the destination and can grant
mint rights. The `ERC20LockBox` is only needed on the chain where tokens are locked. The destination
chain uses a standard `BurnMintTokenPool`, which requires mint and burn rights on the destination token.

```bash
# 1. Deploy ERC20LockBox first (pool address isn't known yet)
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
# Optional: add AUTHORIZED_CALLERS=<DEPLOYER_OR_TOKEN_ISSUER_EOA> to the command above to authorize initial liquidity deposits/withdrawals

# 2. Deploy LockRelease pool, passing the lockbox address from step 1
LOCK_BOX=<LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 3. Authorize the pool to call the lockbox (deposit/withdraw)
LOCK_BOX=<LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# 4. BurnMint pool on Mantle Sepolia (minting side)
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

### Pattern B: lock on source, release on destination

The token already exists on both chains independently. Each chain needs its own `ERC20LockBox` and
`LockReleaseTokenPool`.

```bash
# 1. Deploy ERC20LockBox on Ethereum Sepolia
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 2. Deploy ERC20LockBox on Mantle Sepolia
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# Optional: add AUTHORIZED_CALLERS=<DEPLOYER_OR_TOKEN_ISSUER_EOA> to either or both commands below for initial liquidity management

# 3. Deploy LockRelease pool on Ethereum Sepolia, passing its lockbox address from step 1
LOCK_BOX=<ETHEREUM_SEPOLIA_LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 4. Authorize the Ethereum Sepolia pool on its lockbox
LOCK_BOX=<ETHEREUM_SEPOLIA_LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<ETHEREUM_SEPOLIA_POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# 5. Deploy LockRelease pool on Mantle Sepolia, passing its lockbox address from step 2
LOCK_BOX=<MANTLE_SEPOLIA_LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 6. Authorize the Mantle Sepolia pool on its lockbox
LOCK_BOX=<MANTLE_SEPOLIA_LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<MANTLE_SEPOLIA_POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Each deployment is saved to `history/`:

- ERC20LockBox to `history/lock-boxes/{selectorName}/{timestamp}-{SYMBOL}-LockBox.json` (keys `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`)
- LockReleaseTokenPool to `history/token-pools/{selectorName}/{timestamp}-{SYMBOL}-LockReleaseTokenPool.json` (keys `{CHAIN_NAME_IDENTIFIER}_TOKEN_POOL`, `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`)

The LockRelease pool deploy also resolves `LOCK_BOX` from the registry once a lockbox is recorded.

To verify the lockbox address is correctly attached to the pool:

```bash
forge script script/configure/GetLockBox.s.sol --rpc-url $MANTLE_SEPOLIA_RPC_URL
```

For managing LockRelease liquidity after deploy (the rebalancer model on v1.x pools versus the lockbox
model on v2.0), see [LockRelease liquidity](liquidity.md).
