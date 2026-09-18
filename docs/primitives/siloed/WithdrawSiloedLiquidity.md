---
name: WithdrawSiloedLiquidity
script: script/configure/siloed/WithdrawSiloedLiquidity.s.sol
group: siloed
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: true
---

# WithdrawSiloedLiquidity

Withdraws liquidity from one silo of a SiloedLockReleaseTokenPool 1.6.x to the silo rebalancer.

## Inputs

| Env var | Description |
| --- | --- |
| `AMOUNT` | See the script header. |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/siloed/WithdrawSiloedLiquidity.s.sol`](../../../script/configure/siloed/WithdrawSiloedLiquidity.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
