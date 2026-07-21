---
name: TransferTokenAdminRole
script: script/setup/TransferTokenAdminRole.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# TransferTokenAdminRole

Initiates a transfer of the token admin role to a new address.

## Inputs

| Env var | Description |
| --- | --- |
| `NEW_ADMIN` | See the script header. |

## Reference

- Script: [`script/setup/TransferTokenAdminRole.s.sol`](../../../script/setup/TransferTokenAdminRole.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
