---
name: ClaimAdmin
script: script/setup/ClaimAdmin.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# ClaimAdmin

Registers the token administrator in the TokenAdminRegistry, auto-detecting the claim path (getCCIPAdmin, then owner, then AccessControl DEFAULT_ADMIN_ROLE) in that precedence.

## Inputs

| Env var | Description |
| --- | --- |
| `CCIP_ADMIN_ADDRESS` | See the script header. |

## Reference

- Script: [`script/setup/ClaimAdmin.s.sol`](../../../script/setup/ClaimAdmin.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
