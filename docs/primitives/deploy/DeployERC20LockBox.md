---
name: DeployERC20LockBox
script: script/deploy/DeployERC20LockBox.s.sol
group: deploy
type: reference
modes: [eoa]
read_only: false
writes_onchain: true
destructive: false
---

# DeployERC20LockBox

Script to deploy an ERC20LockBox for use with a LockReleaseTokenPool

## Inputs

| Env var | Description |
| --- | --- |
| `AUTHORIZED_CALLERS` | See the script header. |

## Reference

- Script: [`script/deploy/DeployERC20LockBox.s.sol`](../../../script/deploy/DeployERC20LockBox.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
