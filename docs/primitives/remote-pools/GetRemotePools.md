---
name: GetRemotePools
script: script/configure/remote-pools/GetRemotePools.s.sol
group: remote-pools
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetRemotePools

Reads and displays the remote pool addresses configured on a TokenPool for a given remote chain.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/remote-pools/GetRemotePools.s.sol`](../../../script/configure/remote-pools/GetRemotePools.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
