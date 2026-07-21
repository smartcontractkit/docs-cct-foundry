---
name: GetCCVConfig
script: script/configure/ccv/GetCCVConfig.s.sol
group: ccv
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetCCVConfig

Reads and displays the CCV (Cross-Chain Verifier) configuration for a token pool: every configured remote lane's four verifier arrays plus the pool-global additional-CCV threshold.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/configure/ccv/GetCCVConfig.s.sol`](../../../script/configure/ccv/GetCCVConfig.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
