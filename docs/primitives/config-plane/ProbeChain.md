---
name: ProbeChain
script: script/config/ProbeChain.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# ProbeChain

Read a chain's CCIP wiring over plain JSON-RPC, WITHOUT forking it.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/config/ProbeChain.s.sol`](../../../script/config/ProbeChain.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
