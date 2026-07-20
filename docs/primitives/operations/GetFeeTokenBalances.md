---
name: GetFeeTokenBalances
script: script/operations/GetFeeTokenBalances.s.sol
group: operations
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetFeeTokenBalances

Displays the fee token balances currently held by a token pool.

## Inputs

| Env var | Description |
| --- | --- |
| `FEE_TOKENS` | See the script header. |

## Reference

- Script: [`script/operations/GetFeeTokenBalances.s.sol`](../../../script/operations/GetFeeTokenBalances.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
