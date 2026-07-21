---
name: TransferOwnership
script: script/setup/transfer-ownership/TransferOwnership.s.sol
group: ownership
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# TransferOwnership

Initiates a two-step ownership transfer for any Ownable contract (a token pool, pool hooks, or a lockbox).

## Inputs

| Env var | Description |
| --- | --- |
| `ADDRESS` | See the script header. |
| `NEW_OWNER` | See the script header. |

## Reference

- Script: [`script/setup/transfer-ownership/TransferOwnership.s.sol`](../../../script/setup/transfer-ownership/TransferOwnership.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
