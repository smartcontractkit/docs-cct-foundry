---
name: GetAuthorizedCallers
script: script/configure/authorized-callers/GetAuthorizedCallers.s.sol
group: authorized-callers
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetAuthorizedCallers

Script to fetch and print the authorized callers from an AdvancedPoolHooks or ERC20LockBox contract Usage: POOL_HOOKS=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME LOCK_BOX=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME Environment variables: POOL_HOOKS -- address of an AdvancedPoolHooks contract (one of POOL_HOOKS or LOCK_BOX required) LOCK_BOX -- address of an ERC20LockBox contract (one of POOL_HOOKS or LOCK_BOX required) /

## Inputs

| Env var | Description |
| --- | --- |
| `LOCK_BOX` | See the script header. |
| `POOL_HOOKS` | See the script header. |

## Reference

- Script: [`script/configure/authorized-callers/GetAuthorizedCallers.s.sol`](../../../script/configure/authorized-callers/GetAuthorizedCallers.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
