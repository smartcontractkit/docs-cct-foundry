---
name: ExecuteBatch
script: script/governance/ExecuteBatch.s.sol
group: governance
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# ExecuteBatch

Composes several independently emitted Safe batches into ONE Safe meta-transaction.

## Inputs

| Env var | Description |
| --- | --- |
| `BATCH_FILES` | See the script header. |
| `BATCH_NAME` | See the script header. |
| `SAFE_ADDRESS` | See the script header. |

## Reference

- Script: [`script/governance/ExecuteBatch.s.sol`](../../../script/governance/ExecuteBatch.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
