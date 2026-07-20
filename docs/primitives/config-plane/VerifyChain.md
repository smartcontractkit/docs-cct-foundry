---
name: VerifyChain
script: script/config/VerifyChain.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# VerifyChain

The layered chain-config doctor.

## Inputs

| Env var | Description |
| --- | --- |
| `FOUNDRY_PROFILE` | See the script header. |

## Reference

- Script: [`script/config/VerifyChain.s.sol`](../../../script/config/VerifyChain.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
