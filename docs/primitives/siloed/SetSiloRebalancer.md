---
name: SetSiloRebalancer
script: script/configure/siloed/SetSiloRebalancer.s.sol
group: siloed
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# SetSiloRebalancer

Sets the rebalancer of one silo on a SiloedLockReleaseTokenPool 1.6.x (onlyOwner).

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `REBALANCER` | See the script header. |

## Reference

- Script: [`script/configure/siloed/SetSiloRebalancer.s.sol`](../../../script/configure/siloed/SetSiloRebalancer.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
