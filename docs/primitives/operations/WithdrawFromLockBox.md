---
name: WithdrawFromLockBox
script: script/operations/WithdrawFromLockBox.s.sol
group: operations
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# WithdrawFromLockBox

Script to withdraw tokens from an ERC20LockBox

## Inputs

| Env var | Description |
| --- | --- |
| `AMOUNT` | See the script header. |
| `LOCK_BOX` | See the script header. |
| `RECIPIENT` | See the script header. |

## Reference

- Script: [`script/operations/WithdrawFromLockBox.s.sol`](../../../script/operations/WithdrawFromLockBox.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
