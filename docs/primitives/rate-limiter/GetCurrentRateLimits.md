---
name: GetCurrentRateLimits
script: script/configure/rate-limiter/GetCurrentRateLimits.s.sol
group: rate-limiter
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetCurrentRateLimits

Reads and displays the current rate limiter state for a TokenPool, compatible with v1 and v2 pools.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `FAST_FINALITY` | See the script header. |

## Reference

- Script: [`script/configure/rate-limiter/GetCurrentRateLimits.s.sol`](../../../script/configure/rate-limiter/GetCurrentRateLimits.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
