---
name: UpdateAuthorizedCallers
script: script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol
group: authorized-callers
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateAuthorizedCallers

Script to add or remove authorized callers on an AdvancedPoolHooks or ERC20LockBox contract

## Inputs

| Env var | Description |
| --- | --- |
| `ADD_ADDRESSES` | See the script header. |
| `LOCK_BOX` | See the script header. |
| `POOL_HOOKS` | See the script header. |
| `REMOVE_ADDRESSES` | See the script header. |

## Reference

- Script: [`script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol`](../../../script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
