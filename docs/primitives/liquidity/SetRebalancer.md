---
name: SetRebalancer
script: script/configure/liquidity/SetRebalancer.s.sol
group: liquidity
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetRebalancer

Sets the rebalancer on a v1.x LockRelease token pool (`setRebalancer`, onlyOwner).

## Inputs

| Env var | Description |
| --- | --- |
| `REBALANCER` | See the script header. |

## Reference

- Script: [`script/configure/liquidity/SetRebalancer.s.sol`](../../../script/configure/liquidity/SetRebalancer.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
