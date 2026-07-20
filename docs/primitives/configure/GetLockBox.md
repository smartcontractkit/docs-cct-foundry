---
name: GetLockBox
script: script/configure/GetLockBox.s.sol
group: configure
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetLockBox

Reads and displays the ERC20LockBox contract address currently attached to a LockReleaseTokenPool.

## Inputs

No environment inputs; resolves everything from the chain config and address registry.

## Reference

- Script: [`script/configure/GetLockBox.s.sol`](../../../script/configure/GetLockBox.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
