---
name: UpdateAdvancedPoolHooks
script: script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol
group: allowlist
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateAdvancedPoolHooks

Script to update the AdvancedPoolHooks address for a deployed TokenPool

## Inputs

| Env var | Description |
| --- | --- |
| `NEW_HOOK` | See the script header. |
| `TOKEN_POOL` | See the script header. |

## Reference

- Script: [`script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol`](../../../script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
