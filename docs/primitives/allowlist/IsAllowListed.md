---
name: IsAllowListed
script: script/configure/allowlist/IsAllowListed.s.sol
group: allowlist
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# IsAllowListed

Script to check if an address is allowlisted in an AdvancedPoolHooks contract Usage: POOL_HOOKS=0x...

## Inputs

| Env var | Description |
| --- | --- |
| `CHECK_ADDRESS` | See the script header. |
| `POOL_HOOKS` | See the script header. |

## Reference

- Script: [`script/configure/allowlist/IsAllowListed.s.sol`](../../../script/configure/allowlist/IsAllowListed.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
