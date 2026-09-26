---
name: GetPolicyEngine
script: script/configure/policy-engine/GetPolicyEngine.s.sol
group: policy-engine
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetPolicyEngine

Script to read the ACE Policy Engine address currently set on an AdvancedPoolHooks contract Usage: POOL_HOOKS=0x... forge script script/configure/policy-engine/GetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL /

**When to use.** Read which ACE Policy Engine an AdvancedPoolHooks contract points at, or confirm none is set (policy checks disabled).

## Inputs

| Env var | Description |
| --- | --- |
| `POOL_HOOKS` | Address of the AdvancedPoolHooks contract. Resolves via the standard ladder: inline alias > {CHAIN}_POOL_HOOKS env > registry active.poolHooks. |

## Reference

- Script: [`script/configure/policy-engine/GetPolicyEngine.s.sol`](../../../script/configure/policy-engine/GetPolicyEngine.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
