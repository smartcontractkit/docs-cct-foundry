---
name: DeploySiloedLockReleaseTokenPool
script: script/deploy/DeploySiloedLockReleaseTokenPool.s.sol
group: deploy
type: reference
modes: [eoa]
read_only: false
writes_onchain: true
destructive: false
---

# DeploySiloedLockReleaseTokenPool

Deploys a SiloedLockRelease token pool and records it in the registry.

## Inputs

| Env var | Description |
| --- | --- |
| `DECIMALS` | See the script header. |
| `POOL_HOOKS` | See the script header. |

## Reference

- Script: [`script/deploy/DeploySiloedLockReleaseTokenPool.s.sol`](../../../script/deploy/DeploySiloedLockReleaseTokenPool.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
