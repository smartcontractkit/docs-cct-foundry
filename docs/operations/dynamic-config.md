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
| `RATE_LIMIT_ADMIN` | No       | Rate limit admin address (default: current on-chain value, then broadcaster)                                                            |
| `FEE_ADMIN`        | No       | Fee admin address (default: current on-chain value, then broadcaster). Set to `address(0)` to restrict fee withdrawal to the owner only |
