---
name: GetTokenTransferFeeConfig
script: script/configure/fee-config/GetTokenTransferFeeConfig.s.sol
group: fee-config
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetTokenTransferFeeConfig

Reads and displays the token transfer fee configuration for a token pool on a given destination lane.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/fee-config/GetTokenTransferFeeConfig.s.sol`](../../../script/configure/fee-config/GetTokenTransferFeeConfig.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
