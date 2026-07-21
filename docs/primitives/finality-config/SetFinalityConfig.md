---
name: SetFinalityConfig
script: script/configure/finality-config/SetFinalityConfig.s.sol
group: finality-config
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetFinalityConfig

Sets the allowed finality configuration on a TokenPool, and optionally updates rate limits for the fast finality bucket on a specific remote chain lane.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/finality-config/SetFinalityConfig.s.sol`](../../../script/configure/finality-config/SetFinalityConfig.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
