---
type: reference
---

# Token transfer fee config

Token pools v2.0 and later let token issuers configure fee parameters directly on the pool, overriding
FeeQuoter defaults. Scripts under `script/configure/fee-config/`. Primitive pages:
[`GetTokenTransferFeeConfig`](../primitives/fee-config/GetTokenTransferFeeConfig.md),
[`UpdateTokenTransferFeeConfig`](../primitives/fee-config/UpdateTokenTransferFeeConfig.md). Concept
background: [Fees](../concepts/fees.md).

If run against a v1 pool, these scripts exit with an informative message: on v1, fee configuration is
managed entirely by FeeQuoter and must be requested from the Chainlink team.

## View fee config

Reads the raw stored fee configuration for a destination lane.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/fee-config/GetTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

## Set or update fee config

All fee config env vars are optional. Each field resolves independently: an env var wins when set; an
unset field takes the declared `lanes.<remote>.v2.feeConfig.<field>` from `project/<local>.json` when the
block declares it; otherwise it keeps the current on-chain value. The golden path for v2 lanes is to
declare the whole fee config in `v2.feeConfig` and run the script with no fee env vars. Env vars remain
the explicit override for incident response: a value that disagrees with the declaration is applied as-is
with a per-field divergence notice plus a hand-edit hint, and `make doctor` FAILs until the declaration is
reconciled (applies never write `lanes{}` back). When setting a fee config for the first time with no
declaration and no env vars, unset fields default to `0`.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  DEST_GAS_OVERHEAD=50000 \
  DEST_BYTES_OVERHEAD=32 \
  FINALITY_FEE_USD_CENTS=0 \
  FAST_FINALITY_FEE_USD_CENTS=1000 \
  FINALITY_TRANSFER_FEE_BPS=0 \
  FAST_FINALITY_TRANSFER_FEE_BPS=1000 \
  forge script \
  script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var                          | Required | Description                                                                                                                                                              |
| -------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`                     | Yes      | Remote chain to configure fees for                                                                                                                                     |
| `DEST_GAS_OVERHEAD`              | No       | Gas overhead charged on the destination chain (must be > 0; defaults to the declared `v2.feeConfig` value, then the current on-chain value)                            |
| `DEST_BYTES_OVERHEAD`            | No       | Data availability bytes overhead (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                                      |
| `FINALITY_FEE_USD_CENTS`         | No       | Flat fee in 0.01 USD units for finality transfers (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                     |
| `FAST_FINALITY_FEE_USD_CENTS`    | No       | Flat fee in 0.01 USD units for fast finality transfers (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                |
| `FINALITY_TRANSFER_FEE_BPS`      | No       | Fee in basis points deducted from the transferred amount for finality transfers, 0 to 9999 (defaults to the declared `v2.feeConfig` value, then the on-chain value)    |
| `FAST_FINALITY_TRANSFER_FEE_BPS` | No       | Fee in basis points deducted from the transferred amount for fast finality transfers, 0 to 9999 (defaults to the declared `v2.feeConfig` value, then the on-chain value) |
| `DISABLE`                        | No       | Set to `true` to disable the fee config for this lane, reverting the OnRamp to FeeQuoter defaults (default `false`)                                                    |

## Disable fee config

Disabling the fee config for a lane causes the OnRamp to fall back to FeeQuoter defaults.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  DISABLE=true \
  forge script \
  script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```
