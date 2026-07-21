---
name: TransferTokenAdmin
script: script/setup/token-roles/TransferTokenAdmin.s.sol
group: token-roles
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# TransferTokenAdmin

Moves the token's TOP-LEVEL admin (its template's own mechanism).

## Inputs

| Env var | Description |
| --- | --- |
| `ACCEPT` | See the script header. |
| `NEW_ADMIN` | See the script header. |

## Reference

- Script: [`script/setup/token-roles/TransferTokenAdmin.s.sol`](../../../script/setup/token-roles/TransferTokenAdmin.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
