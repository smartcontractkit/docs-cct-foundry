---
name: ProvideLiquidity
script: script/configure/liquidity/ProvideLiquidity.s.sol
group: liquidity
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# ProvideLiquidity

Provides lock/release liquidity to a v1.x LockRelease token pool (`provideLiquidity`).

## Inputs

| Env var | Description |
| --- | --- |
| `AMOUNT` | See the script header. |

## Reference

- Script: [`script/configure/liquidity/ProvideLiquidity.s.sol`](../../../script/configure/liquidity/ProvideLiquidity.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
