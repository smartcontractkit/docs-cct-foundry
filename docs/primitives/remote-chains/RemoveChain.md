---
name: RemoveChain
script: script/configure/remote-chains/RemoveChain.s.sol
group: remote-chains
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# RemoveChain

Fully unsupports a remote chain on the source TokenPool: removes the chain selector and deletes its remote-chain config (pools, remote token, rate limits).

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |

## Reference

- Script: [`script/configure/remote-chains/RemoveChain.s.sol`](../../../script/configure/remote-chains/RemoveChain.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
