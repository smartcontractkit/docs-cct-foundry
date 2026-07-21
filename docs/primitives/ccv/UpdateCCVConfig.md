---
name: UpdateCCVConfig
script: script/configure/ccv/UpdateCCVConfig.s.sol
group: ccv
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# UpdateCCVConfig

Applies CCV (Cross-Chain Verifier) configuration to a token pool's AdvancedPoolHooks: the four per-lane verifier arrays and/or the pool-global additional-CCV threshold.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/ccv/UpdateCCVConfig.s.sol`](../../../script/configure/ccv/UpdateCCVConfig.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
