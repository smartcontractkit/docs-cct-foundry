---
name: WithdrawFeeTokens
script: script/operations/WithdrawFeeTokens.s.sol
group: operations
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# WithdrawFeeTokens

Withdraws accrued fee token balances from a token pool to a specified recipient.

## Inputs

| Env var | Description |
| --- | --- |
| `FEE_TOKENS` | See the script header. |
| `RECIPIENT` | See the script header. |

## Reference

- Script: [`script/operations/WithdrawFeeTokens.s.sol`](../../../script/operations/WithdrawFeeTokens.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
