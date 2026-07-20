---
type: reference
---

# Finality config

Read and set the fast finality configuration on a pool. Requires TokenPool v2.0 or later. The finality
config controls which fast finality modes the pool accepts for cross-chain transfers. Scripts under
`script/configure/finality-config/`. Primitive pages:
[`GetFinalityConfig`](../primitives/finality-config/GetFinalityConfig.md),
[`SetFinalityConfig`](../primitives/finality-config/SetFinalityConfig.md).

Setting it to `WAIT_FOR_FINALITY` (no env vars, no declaration, the default) disables fast finality
transfers. The golden path is to declare the policy in `poolPolicy.finality` in `project/<local>.json`
and run the script with no finality env vars: the declaration drives the apply and the doctor reconciles
it (see [Config and project-store
schema](../config-schema.md#the-poolpolicy-block---pool-scoped-policy)).

## View finality config

```bash
forge script script/configure/finality-config/GetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

## Set finality config

When enabling fast finality, consider configuring the fast finality bucket rate limits at the same time.
If the fast finality bucket is not configured, fast finality transfers fall back to the standard finality
bucket. Configuring it explicitly gives isolated, independently tuned rate limits for fast finality
transfers, useful when their volume or risk profile differs from standard finality transfers.

```bash
# Set block depth and configure the fast finality rate limit bucket:
BLOCK_DEPTH=5 \
  DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Set block depth only (no rate limit changes):
BLOCK_DEPTH=5 \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Set WAIT_FOR_SAFE mode and view current rate limits for a lane (no update):
WAIT_FOR_SAFE=true \
  DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Combine BLOCK_DEPTH and WAIT_FOR_SAFE (pool accepts either mode simultaneously):
BLOCK_DEPTH=5 \
  WAIT_FOR_SAFE=true \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Apply the declared poolPolicy.finality (or reset to default finality when nothing is declared):
forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

The applied value resolves through the standard ladder: env (`WAIT_FOR_SAFE`/`BLOCK_DEPTH`, either
present, where an explicit `false`/`0` still counts) > declared `poolPolicy.finality` (`{blockDepth,
waitForSafe}`; an empty block `{}` declares the WAIT_FOR_FINALITY default) > the WAIT_FOR_FINALITY reset.
An env override that diverges from (or is missing in) the declaration prints a divergence notice plus a
hand-edit hint, and `make doctor` FAILs until reconciled. Applies never write `poolPolicy{}` back.

When `DEST_CHAIN` is provided, the script logs the current rate limits before applying any changes, and
the updated state after. Each direction is shown independently: the fast finality bucket is displayed for
directions where it is enabled; the standard finality bucket (fallback) is displayed for directions where
it is not.

| Env var                        | Required | Description                                                                                                                                                                |
| ------------------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `BLOCK_DEPTH`                  | No       | Number of block confirmations for fast finality (1 to 65535). Can be combined with `WAIT_FOR_SAFE` to allow both modes simultaneously. Omit both to reset to default finality. |
| `WAIT_FOR_SAFE`                | No       | Set to `true` to use the `safe` head for fast finality. Can be combined with `BLOCK_DEPTH` to allow both modes simultaneously.                                            |
| `DEST_CHAIN`                   | No       | Remote chain whose lane is queried or updated (for example `MANTLE_SEPOLIA`). Required when any rate limit var is set; if omitted, the rate limiter section is skipped.   |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No       | uint128, outbound token bucket capacity (fast finality bucket)                                                                                                            |
| `OUTBOUND_RATE_LIMIT_RATE`     | No       | uint128, outbound token bucket refill rate (tokens/second)                                                                                                                |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set)                                                                    |
| `INBOUND_RATE_LIMIT_CAPACITY`  | No       | uint128, inbound token bucket capacity (fast finality bucket)                                                                                                             |
| `INBOUND_RATE_LIMIT_RATE`      | No       | uint128, inbound token bucket refill rate (tokens/second)                                                                                                                 |
| `INBOUND_RATE_LIMIT_ENABLED`   | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set)                                                                    |
