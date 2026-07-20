---
name: UpdateTokenTransferFeeConfig
script: script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol
group: fee-config
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateTokenTransferFeeConfig

Applies token transfer fee configuration updates to a token pool on a given destination lane.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `DISABLE` | See the script header. |

## Reference

- Script: [`script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol`](../../../script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
