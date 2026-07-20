---
name: MintTokens
script: script/operations/MintTokens.s.sol
group: operations
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# MintTokens

Mints tokens to a receiver (requires the signer to hold the token's minter role).

## Inputs

| Env var | Description |
| --- | --- |
| `AMOUNT` | See the script header. |
| `MINT_RECEIVER` | See the script header. |

## Reference

- Script: [`script/operations/MintTokens.s.sol`](../../../script/operations/MintTokens.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
