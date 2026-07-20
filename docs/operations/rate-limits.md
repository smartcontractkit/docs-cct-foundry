---
type: reference
---

# Rate limits

Read and update the per-lane token bucket rate limiters on a pool. Compatible with both v1 and v2 pools.
Scripts under `script/configure/rate-limiter/`. Primitive pages:
[`GetCurrentRateLimits`](../primitives/rate-limiter/GetCurrentRateLimits.md),
[`UpdateRateLimiters`](../primitives/rate-limiter/UpdateRateLimiters.md). Per-version validation and
pause behavior live in [Pool versions](../pool-versions.md).

The standard finality bucket is also configurable at lane-apply time; see [Lanes and remote
pools](lanes-and-remotes.md). Use `UpdateRateLimiters` for standalone updates and for the fast finality
bucket (`FAST_FINALITY=true`, v2 pools only).

## View current rate limits

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/rate-limiter/GetCurrentRateLimits.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

Set `FAST_FINALITY=true` to query the fast finality bucket (v2 pools only). Each direction is shown
independently: the fast finality bucket is displayed where it is enabled; the standard finality bucket
(fallback) is displayed where it is not.

## Update rate limits

The direction is inferred automatically from whichever `OUTBOUND_*` / `INBOUND_*` vars are set, so there
is no need to pass a separate enabled flag. A bucket is enabled automatically when its `*_CAPACITY` or
`*_RATE` is set; pass `OUTBOUND_RATE_LIMIT_ENABLED=false` (or the inbound equivalent) to disable it
explicitly.

The golden path for v2 lanes is to declare the policy in the local chain config and apply from the
declaration: with no rate-limit env vars, a direction resolves from the `lanes{}` entry in
`project/<local>.json` (the standard bucket from `capacity`/`rate` plus the optional `inbound{}` block,
the fast finality bucket from `v2.fastFinality.outbound` / `v2.fastFinality.inbound` on 2.0.0 pools with
`FAST_FINALITY=true`). Env vars remain the explicit override for incident response: they win as-is, and
when they disagree with (or are missing from) the declaration, the script prints a divergence notice plus
a hand-edit hint with the applied values, and `make doctor` FAILs until the declaration is reconciled.
Applies never write `lanes{}` back. See [Config and project-store schema](../config-schema.md).

```bash
# Enable both directions (ENABLED is optional - defaults to true when CAPACITY/RATE are set)
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable outbound only
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable inbound only
DEST_CHAIN=MANTLE_SEPOLIA \
  INBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable both directions
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_ENABLED=false \
  INBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var                        | Required                                          | Description                                                                                        |
| ------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`                   | Yes                                               | Remote chain whose lane is being updated                                                           |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | To update outbound (unless declared in `lanes{}`) | Token bucket capacity for outbound transfers                                                       |
| `OUTBOUND_RATE_LIMIT_RATE`     | To update outbound                                | Token bucket refill rate (tokens/second) for outbound transfers                                    |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No                                                | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |
| `INBOUND_RATE_LIMIT_CAPACITY`  | To update inbound (unless declared in `lanes{}`)  | Token bucket capacity for inbound transfers                                                        |
| `INBOUND_RATE_LIMIT_RATE`      | To update inbound                                 | Token bucket refill rate (tokens/second) for inbound transfers                                     |
| `INBOUND_RATE_LIMIT_ENABLED`   | No                                                | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |
| `FAST_FINALITY`                | No                                                | `true` to update the fast finality bucket instead of the standard bucket (v2 only, default `false`) |

## Version behavior

Rate-limit validation and the pause pattern differ by pool version (for example `capacity=1, rate=1` reverts on v1.5.x but is valid on v1.6+/v2.0). See the fixture-backed [pool-version behavior deltas](../reference/pool-behavior-matrix.md).
