---
name: SetCCIPAdmin
script: script/setup/token-roles/SetCCIPAdmin.s.sol
group: token-roles
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetCCIPAdmin

Sets the token's CCIP admin (`setCCIPAdmin`, one-step, no accept).

## Inputs

| Env var | Description |
| --- | --- |
| `CCIP_ADMIN_ADDRESS` | See the script header. |

## Reference

- Script: [`script/setup/token-roles/SetCCIPAdmin.s.sol`](../../../script/setup/token-roles/SetCCIPAdmin.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
