---
name: SetPolicyEngine
script: script/configure/policy-engine/SetPolicyEngine.s.sol
group: policy-engine
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# SetPolicyEngine

Script to point an AdvancedPoolHooks contract at an ACE Policy Engine on the same chain, or disconnect the engine with the zero address.

**When to use.** Connect an AdvancedPoolHooks contract to an ACE Policy Engine on the same chain, or disconnect the engine with the zero address. The hook calls attach() on the new engine, which starts ACE target detection.

## Inputs

| Env var | Description |
| --- | --- |
| `POLICY_ENGINE` | Address of the ACE Policy Engine on the same chain, or the zero address to disconnect the engine and stop policy checks. |
| `POOL_HOOKS` | Address of the AdvancedPoolHooks contract. Resolves via the standard ladder: inline alias > {CHAIN}_POOL_HOOKS env > registry active.poolHooks. |

## Preconditions

The executing account is the hooks owner. The engine is deployed on the same chain and Active in the Chainlink Platform.

## Postconditions

The hooks contract points at the new engine; getPolicyEngine returns it.

## Known failure modes

Reverts PolicyEngineDetachReverted when the old engine's detach() reverts; the on-chain recovery path is setPolicyEngineAllowFailedDetach on the hook itself. A same-address update is refused by the script before broadcasting (it would be a no-op that reports success).

## Reference

- Script: [`script/configure/policy-engine/SetPolicyEngine.s.sol`](../../../script/configure/policy-engine/SetPolicyEngine.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
