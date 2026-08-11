---
type: reference
---

# Dynamic config

Read or update the dynamic configuration on a token pool: the CCIP Router, the rate limit admin, and the
fee admin. Scripts under `script/configure/dynamic-config/`. Primitive pages:
[`GetDynamicConfig`](../primitives/dynamic-config/GetDynamicConfig.md),
[`SetDynamicConfig`](../primitives/dynamic-config/SetDynamicConfig.md).

## View dynamic config

```bash
forge script script/configure/dynamic-config/GetDynamicConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

## Set dynamic config

```bash
ROUTER=0xYourRouterAddress \
  forge script \
  script/configure/dynamic-config/SetDynamicConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var            | Required | Description                                                                                                                              |
| ------------------ | -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `ROUTER`           | No       | The CCIP Router address to set on the pool (default: current on-chain value)                                                            |
| `RATE_LIMIT_ADMIN` | No       | Rate limit admin address (default: current on-chain value, verbatim)                                                                    |
| `FEE_ADMIN`        | No       | Fee admin address (default: current on-chain value, verbatim). Set to `address(0)` to restrict fee withdrawal to the owner only         |

An unset variable preserves the pool's current value exactly, `address(0)` included. The call writes the
whole struct, so any other default would turn a one-field update into a silent grant of the others: a
broadcaster fallback, for example, would hand both admin slots to the acting account on a `ROUTER`-only
run whenever they are unset on chain.
