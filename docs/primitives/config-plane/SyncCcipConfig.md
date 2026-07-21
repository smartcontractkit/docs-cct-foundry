---
name: SyncCcipConfig
script: script/config/SyncCcipConfig.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# SyncCcipConfig

The config-sync entrypoints: everything that generates, refreshes, or drift-checks a `config/chains/<name>.json` file from the live CCIP REST API v2.

## Inputs

| Env var | Description |
| --- | --- |
| `CHAIN_NAME_IDENTIFIER` | See the script header. |
| `FOUNDRY_PROFILE` | See the script header. |
| `RPC_ENV` | See the script header. |

## Reference

- Script: [`script/config/SyncCcipConfig.s.sol`](../../../script/config/SyncCcipConfig.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
