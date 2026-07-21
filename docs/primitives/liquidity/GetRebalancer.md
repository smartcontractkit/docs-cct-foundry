---
name: GetRebalancer
script: script/configure/liquidity/GetRebalancer.s.sol
group: liquidity
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetRebalancer

Reads and displays the rebalancer of a v1.x LockRelease token pool (`getRebalancer`).

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/configure/liquidity/GetRebalancer.s.sol`](../../../script/configure/liquidity/GetRebalancer.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
