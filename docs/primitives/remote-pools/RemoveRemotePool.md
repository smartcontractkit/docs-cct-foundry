---
name: RemoveRemotePool
script: script/configure/remote-pools/RemoveRemotePool.s.sol
group: remote-pools
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# RemoveRemotePool

Removes a remote pool address from a TokenPool for a given remote chain.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `REMOTE_POOL_ADDRESS` | See the script header. |

## Reference

- Script: [`script/configure/remote-pools/RemoveRemotePool.s.sol`](../../../script/configure/remote-pools/RemoveRemotePool.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
