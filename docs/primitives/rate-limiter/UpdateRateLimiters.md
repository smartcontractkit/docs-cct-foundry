---
name: UpdateRateLimiters
script: script/configure/rate-limiter/UpdateRateLimiters.s.sol
group: rate-limiter
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateRateLimiters

Updates rate limiter configuration on a TokenPool, compatible with both v1 and v2 pools.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `FAST_FINALITY` | See the script header. |

## Reference

- Script: [`script/configure/rate-limiter/UpdateRateLimiters.s.sol`](../../../script/configure/rate-limiter/UpdateRateLimiters.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
