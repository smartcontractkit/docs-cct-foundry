---
type: reference
---

# Lanes and remote pools

Configure the cross-chain routes on a pool: apply chain updates for a lane, and add or remove the
remote pools registered for each supported remote chain. Scripts under `script/setup/` and
`script/configure/remote-pools/` and `script/configure/remote-chains/`. Primitive pages:
[`ApplyChainUpdates`](../primitives/token-admin-registry/ApplyChainUpdates.md),
[`GetSupportedChains`](../primitives/token-admin-registry/GetSupportedChains.md),
[`GetRemotePools`](../primitives/remote-pools/GetRemotePools.md),
[`AddRemotePool`](../primitives/remote-pools/AddRemotePool.md),
[`RemoveRemotePool`](../primitives/remote-pools/RemoveRemotePool.md),
[`RemoveChain`](../primitives/remote-chains/RemoveChain.md).

## Apply chain updates

Configure the route from the local pool to a destination chain. Run once per direction.

Dry run first: omit `--broadcast` to simulate the apply against the fork and print exactly what it would
do without sending a transaction. Add `--broadcast` once the output looks right.

```bash
# Configure Ethereum Sepolia -> Mantle Sepolia
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Configure Mantle Sepolia -> Ethereum Sepolia
DEST_CHAIN=ETHEREUM_SEPOLIA \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Configure Ethereum Sepolia -> Solana Devnet (non-EVM destination)
DEST_CHAIN=SOLANA_DEVNET \
  SOLANA_DEVNET_TOKEN_POOL=<SOLANA_TOKEN_POOL_ADDRESS> \
  SOLANA_DEVNET_TOKEN=<SOLANA_TOKEN_ADDRESS> \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

For non-EVM chains like Solana Devnet, supply the destination pool and token addresses via
`{DEST_CHAIN}_TOKEN_POOL` and `{DEST_CHAIN}_TOKEN` (for example `SOLANA_DEVNET_TOKEN_POOL`,
`SOLANA_DEVNET_TOKEN`). These are base58-encoded, not `0x`-prefixed EVM addresses. Rate limiting is not
applicable for non-EVM destinations and is ignored.

This script is idempotent: if the destination chain is already configured on the pool, the existing
config is removed and replaced automatically.

### Rate limits: env override versus declared policy

Rate limits resolve per direction through a two-rung ladder, matching the repo's `inline > env >
registry` idiom:

1. Rate-limit env vars set: the env values win, exactly as documented in the table below. This is the
   explicit override path (for example, an incident-response throttle). If the local chain config
   declares a diverging `lanes{}` policy for the destination, the script prints a one-line notice naming
   both values, and the closing output prints the exact `make add-lane` command to bring the declaration
   in line. `make doctor` FAILs until the two agree. An apply never writes `lanes{}` back: the
   declaration is owner intent, reconciled through a reviewed edit.
2. Env vars unset: the buckets come from the declared `lanes{}` entry in the local project store
   `project/<local>.json` (matched by the remote's config name, falling back to `remoteSelector`
   equality). `capacity`/`rate` drive the outbound bucket (enabled when either is non-zero), and the
   optional `inbound{capacity,rate}` block drives the inbound bucket. An absent `inbound{}` block keeps
   the default: disabled.

With neither env vars nor a `lanes{}` entry, rate limiting stays disabled (the historical default) and
the console says so. The golden path is declare once, apply from the declaration: `make add-lane` (see
[Chains and config tooling](chains.md)), then run the script with no rate-limit env vars.

To enable rate limits via the env override, pass the capacity and rate; `isEnabled` is automatically set
to `true` when either value is provided:

```bash
# Ethereum Sepolia -> Mantle Sepolia: enable both directions
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Mantle Sepolia -> Ethereum Sepolia: enable both directions
DEST_CHAIN=ETHEREUM_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Enable outbound only (Sepolia -> Mantle)
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Enable inbound only (Sepolia -> Mantle)
DEST_CHAIN=MANTLE_SEPOLIA \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var                        | Required | Description                                                                                          |
| ------------------------------ | -------- | --------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`                   | Yes      | Destination chain name (for example `MANTLE_SEPOLIA`)                                                |
| `TOKEN_POOL`                   | No       | Inline alias for the source chain pool address. Takes priority over `{CHAIN}_TOKEN_POOL`.            |
| `DEST_TOKEN_POOL`              | No       | Inline alias for the destination chain pool address. Takes priority over `{DEST_CHAIN}_TOKEN_POOL`.  |
| `DEST_TOKEN`                   | No       | Inline alias for the destination chain token address. Takes priority over `{DEST_CHAIN}_TOKEN`.      |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No       | Token bucket capacity for outbound transfers                                                         |
| `OUTBOUND_RATE_LIMIT_RATE`     | No       | Token bucket refill rate (tokens/second) for outbound transfers                                      |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)   |
| `INBOUND_RATE_LIMIT_CAPACITY`  | No       | Token bucket capacity for inbound transfers                                                          |
| `INBOUND_RATE_LIMIT_RATE`      | No       | Token bucket refill rate (tokens/second) for inbound transfers                                       |
| `INBOUND_RATE_LIMIT_ENABLED`   | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)   |

`ApplyChainUpdates` only configures the standard finality rate limit bucket. To configure the fast
finality bucket, run `UpdateRateLimiters` with `FAST_FINALITY=true` after the lane is set up (see [Rate
limits](rate-limits.md)).

### Declare versus apply: argument name mapping

`make add-lane` (which declares the policy into the local project store `project/<local>.json`) and the
apply scripts (`ApplyChainUpdates`, `UpdateRateLimiters`) name the same rate-limit values differently.
When translating a declared lane into an env-override apply, map the arguments as follows:

| `make add-lane` argument | Apply-script env var           |
| ------------------------ | ------------------------------ |
| `REMOTE`                 | `DEST_CHAIN`                   |
| `CAPACITY`               | `OUTBOUND_RATE_LIMIT_CAPACITY` |
| `RATE`                   | `OUTBOUND_RATE_LIMIT_RATE`     |
| `INBOUND_CAPACITY`       | `INBOUND_RATE_LIMIT_CAPACITY`  |
| `INBOUND_RATE`           | `INBOUND_RATE_LIMIT_RATE`      |

`LOCAL` names the source chain, the chain whose pool is being configured. The apply scripts infer the
source chain from the `--rpc-url` you pass (its `block.chainid`), so there is no `LOCAL` env var: point
`--rpc-url` at the source chain's RPC.

To read the list of supported chains and their remote pool addresses:

```bash
forge script script/setup/GetSupportedChains.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

## Remote pools

Remote pools are the pool addresses registered on a given chain for each supported remote chain. When a
pool is upgraded on a remote chain, keep the old address active until all inflight messages have
completed, then remove it.

### View remote pools

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/remote-pools/GetRemotePools.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

### Add a remote pool

Use after upgrading a pool on a remote chain. The old and new pool addresses can be active
simultaneously to let inflight messages complete.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  REMOTE_POOL_ADDRESS=0xNewRemotePoolAddress \
  forge script \
  script/configure/remote-pools/AddRemotePool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Remove a remote pool

Drops a single remote pool from a chain that stays supported. This is a 1.5.1+ operation; on a 1.5.0
pool it refuses and points at "Remove a remote chain" below, since 1.5.0 holds one remote pool per chain
(there is no standalone pool removal).

All inflight transactions from the removed pool are rejected after removal. Ensure there are no inflight
transactions before proceeding.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  REMOTE_POOL_ADDRESS=0xOldRemotePoolAddress \
  forge script \
  script/configure/remote-pools/RemoveRemotePool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Remove a remote chain

Tears down the whole lane: fully unsupports a remote chain on the source pool (removes the selector and
deletes its remote-chain config), so neither direction accepts messages afterward. Use this to retire a
lane, not to swap a pool. Works on every pool version (1.5.0 through 2.0.0); the script dispatches on the
pool's on-chain version.

All inflight transactions on this lane are rejected after removal. Ensure there are no inflight messages
to or from this chain before proceeding. See [Pool
versions](../pool-versions.md#removing-a-lane-or-a-pool) for the live-lane drain sequence and the config
that survives removal.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/remote-chains/RemoveChain.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```
