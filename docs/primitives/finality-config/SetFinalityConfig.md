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
| `DEST_CHAIN_SELECTOR` | See the script header. |
| `INBOUND_RATE_LIMIT_CAPACITY` | uint128 token-bucket capacity (inbound). Same all-or-nothing rule per direction. |
| `INBOUND_RATE_LIMIT_ENABLED` | true/false; defaults to true when CAPACITY or RATE are set. false stands alone as a disable. |
| `INBOUND_RATE_LIMIT_RATE` | uint128 token-bucket refill rate (inbound). |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | uint128 token-bucket capacity. Per direction the inputs are all-or-nothing: an enabled bucket needs CAPACITY and RATE together, and a partial set is refused naming the missing variable. |
| `OUTBOUND_RATE_LIMIT_ENABLED` | true/false; defaults to true when CAPACITY or RATE are set. false stands alone as a disable. |
| `OUTBOUND_RATE_LIMIT_RATE` | uint128 token-bucket refill rate. An enabled bucket needs CAPACITY and RATE together. |

## Reference

- Script: [`script/configure/finality-config/SetFinalityConfig.s.sol`](../../../script/configure/finality-config/SetFinalityConfig.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
