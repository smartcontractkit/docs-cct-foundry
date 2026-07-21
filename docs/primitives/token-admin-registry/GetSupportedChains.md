---
name: GetSupportedChains
script: script/setup/GetSupportedChains.s.sol
group: token-admin-registry
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetSupportedChains

Reads and displays all remote chains supported by a TokenPool.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/setup/GetSupportedChains.s.sol`](../../../script/setup/GetSupportedChains.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
