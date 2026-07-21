---
name: ApplyChainUpdates
script: script/setup/ApplyChainUpdates.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# ApplyChainUpdates

Configures cross-chain lanes on the source TokenPool by calling applyChainUpdates.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `DEST_CHAIN_FAMILY` | See the script header. |
| `DEST_CHAIN_SELECTOR` | See the script header. |
| `DEST_TOKEN` | See the script header. |
| `DEST_TOKEN_POOL` | See the script header. |
| `VIA_JSON_FILE` | See the script header. |

## Reference

- Script: [`script/setup/ApplyChainUpdates.s.sol`](../../../script/setup/ApplyChainUpdates.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
