---
name: PreflightTransfer
script: script/diagnostics/PreflightTransfer.s.sol
group: diagnostics
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# PreflightTransfer

Preflights a token transfer before any real send by simulating both pool legs against live chain state: the source pool's `lockOrBurn`, then the destination pool's `releaseOrMint` fed the exact `destPoolData` the source leg produced.

## Inputs

| Env var | Description |
| --- | --- |
| `AMOUNT` | See the script header. |
| `DEST_CHAIN` | See the script header. |
| `DEST_POOL` | See the script header. |
| `DEST_RPC_URL` | See the script header. |
| `ORIGINAL_SENDER` | See the script header. |
| `RECEIVER` | See the script header. |
| `REQUESTED_FINALITY` | See the script header. |
| `SOURCE_CHAIN` | See the script header. |
| `SOURCE_POOL` | See the script header. |
| `SOURCE_RPC_URL` | See the script header. |
| `TOKEN_ARGS` | See the script header. |

## Reference

- Script: [`script/diagnostics/PreflightTransfer.s.sol`](../../../script/diagnostics/PreflightTransfer.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
