---
name: GetSiloedPoolState
script: script/configure/siloed/GetSiloedPoolState.s.sol
group: siloed
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetSiloedPoolState

Reads where a SiloedLockReleaseTokenPool keeps its liquidity, per remote chain.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/configure/siloed/GetSiloedPoolState.s.sol`](../../../script/configure/siloed/GetSiloedPoolState.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
