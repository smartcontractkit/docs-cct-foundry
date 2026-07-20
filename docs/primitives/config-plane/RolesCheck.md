---
name: RolesCheck
script: script/config/RolesCheck.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# RolesCheck

**`make roles-check CHAIN=<name>` - READ-ONLY reconcile of the declared `roles{}` against the live chain.** It never writes a file and never broadcasts; the only outputs are the aligned [PASS]/[FAIL]/[WARN]/[SKIP] lines from `RolesAuditor` and the exit status.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/config/RolesCheck.s.sol`](../../../script/config/RolesCheck.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
