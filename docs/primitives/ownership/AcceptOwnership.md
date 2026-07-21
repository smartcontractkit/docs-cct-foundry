---
name: AcceptOwnership
script: script/setup/transfer-ownership/AcceptOwnership.s.sol
group: ownership
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# AcceptOwnership

Completes a two-step ownership transfer initiated by TransferOwnership for any Ownable contract (a token pool, pool hooks, or a lockbox).

## Inputs

| Env var | Description |
| --- | --- |
| `ADDRESS` | See the script header. |

## Reference

- Script: [`script/setup/transfer-ownership/AcceptOwnership.s.sol`](../../../script/setup/transfer-ownership/AcceptOwnership.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
