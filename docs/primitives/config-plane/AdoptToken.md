---
name: AdoptToken
script: script/config/AdoptToken.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# AdoptToken

Adopts an externally deployed token (and optionally its pool) into the address registry, so contracts this repo did NOT deploy resolve exactly like the ones it did (the zero-export `active.<role>` ladder).

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/config/AdoptToken.s.sol`](../../../script/config/AdoptToken.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
