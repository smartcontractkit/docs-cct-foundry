---
name: GetAdvancedPoolHooks
script: script/configure/allowlist/GetAdvancedPoolHooks.s.sol
group: allowlist
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetAdvancedPoolHooks

Reads and displays the AdvancedPoolHooks contract address currently attached to a token pool.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/configure/allowlist/GetAdvancedPoolHooks.s.sol`](../../../script/configure/allowlist/GetAdvancedPoolHooks.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
