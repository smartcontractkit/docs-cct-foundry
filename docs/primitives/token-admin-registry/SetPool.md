---
name: SetPool
script: script/setup/SetPool.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetPool

Points the TokenAdminRegistry at the token's pool, activating the token for cross-chain transfers.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/setup/SetPool.s.sol`](../../../script/setup/SetPool.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
