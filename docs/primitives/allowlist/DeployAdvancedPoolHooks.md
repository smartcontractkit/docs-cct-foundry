---
name: DeployAdvancedPoolHooks
script: script/configure/allowlist/DeployAdvancedPoolHooks.s.sol
group: allowlist
type: reference
modes: [eoa]
read_only: false
writes_onchain: true
destructive: false
---

# DeployAdvancedPoolHooks

Optional script to deploy AdvancedPoolHooks for enhanced token pool security

## Inputs

| Env var | Description |
| --- | --- |
| `ALLOWLIST` | See the script header. |
| `AUTHORIZED_CALLERS` | See the script header. |
| `POLICY_ENGINE` | See the script header. |
| `POOL_TYPE` | See the script header. |
| `THRESHOLD_AMOUNT` | See the script header. |

## Reference

- Script: [`script/configure/allowlist/DeployAdvancedPoolHooks.s.sol`](../../../script/configure/allowlist/DeployAdvancedPoolHooks.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
