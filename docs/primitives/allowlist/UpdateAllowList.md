---
name: UpdateAllowList
script: script/configure/allowlist/UpdateAllowList.s.sol
group: allowlist
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateAllowList

Script to update the allowlist for a TokenPool or AdvancedPoolHooks

## Inputs

| Env var | Description |
| --- | --- |
| `ADD_ADDRESSES` | See the script header. |
| `POOL_HOOKS` | See the script header. |
| `REMOVE_ADDRESSES` | See the script header. |
| `TOKEN_POOL` | See the script header. |

## Reference

- Script: [`script/configure/allowlist/UpdateAllowList.s.sol`](../../../script/configure/allowlist/UpdateAllowList.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
