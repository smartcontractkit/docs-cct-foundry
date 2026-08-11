---
name: SetDynamicConfig
script: script/configure/dynamic-config/SetDynamicConfig.s.sol
group: dynamic-config
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetDynamicConfig

Updates the dynamic configuration of a TokenPool (router, rateLimitAdmin, feeAdmin).

## Inputs

| Env var | Description |
| --- | --- |
| `FEE_ADMIN` | Optional. Unset preserves the current value verbatim; an explicit address(0) restricts fee withdrawal to the owner. |
| `RATE_LIMIT_ADMIN` | Optional. Unset preserves the current on-chain value verbatim, address(0) included. |
| `ROUTER` | Optional. Unset preserves the pool's current on-chain router verbatim. |

## Reference

- Script: [`script/configure/dynamic-config/SetDynamicConfig.s.sol`](../../../script/configure/dynamic-config/SetDynamicConfig.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
