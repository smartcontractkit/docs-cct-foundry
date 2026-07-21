---
name: AcceptAdminRole
script: script/setup/AcceptAdminRole.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# AcceptAdminRole

Accepts the pending administrator role for a token in the TokenAdminRegistry (step 2 of the two-step claim; the signer must be the pending administrator set by ClaimAdmin).

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/setup/AcceptAdminRole.s.sol`](../../../script/setup/AcceptAdminRole.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
