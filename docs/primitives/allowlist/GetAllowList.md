---
name: GetAllowList
script: script/configure/allowlist/GetAllowList.s.sol
group: allowlist
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetAllowList

Script to fetch and print the allowlist from an AdvancedPoolHooks contract Usage: POOL_HOOKS=0x... forge script script/configure/allowlist/GetAllowList.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME /

## Inputs

| Env var | Description |
| --- | --- |
| `POOL_HOOKS` | See the script header. |

## Reference

- Script: [`script/configure/allowlist/GetAllowList.s.sol`](../../../script/configure/allowlist/GetAllowList.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
