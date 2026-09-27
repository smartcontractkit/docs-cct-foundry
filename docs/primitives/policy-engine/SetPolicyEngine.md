---
name: SetPolicyEngine
script: script/configure/policy-engine/SetPolicyEngine.s.sol
group: policy-engine
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# SetPolicyEngine

Script to point an AdvancedPoolHooks contract at an ACE Policy Engine on the same chain, or disconnect the engine with the zero address.

**When to use.** Connect an AdvancedPoolHooks contract to an ACE Policy Engine on the same chain, or disconnect the engine with the zero address. The hook calls attach() on the new engine, which starts ACE target detection.

## Inputs

| Env var | Description |
| --- | --- |
| `ALLOW_FAILED_DETACH` | true calls setPolicyEngineAllowFailedDetach, tolerating a reverting detach() on the old engine (default false). |
| `POLICY_ENGINE` | Address of the ACE Policy Engine on the same chain, or the zero address to disconnect the engine and stop policy checks. |
| `POOL_HOOKS` | Address of the AdvancedPoolHooks contract. Resolves via the standard ladder: inline alias > {CHAIN}_POOL_HOOKS env > registry active.poolHooks. |

## Preconditions

The executing account is the hooks owner (MODE=safe when a Safe owns it). The engine is deployed on the same chain and already provisioned for this hooks address: extractor, policies, and setTargetDefaultPolicyAllow. Every lane into this chain quotes a destGasOverhead that covers postflightCheck (UpdateTokenTransferFeeConfig).

## Postconditions

getPolicyEngine returns the new engine. Run make snapshot-chain: hooks.policyEngine is a governance-critical roles{} field and the old declaration fails roles-check until re-snapshotted.

## Known failure modes

DESTRUCTIVE: the zero address turns compliance checks off, and an unprovisioned engine rejects every transfer (PolicyRunRejected). An engine address with no code and a same-address update are refused before broadcasting. Reverts PolicyEngineDetachReverted when the old engine's detach() reverts; rerun with ALLOW_FAILED_DETACH=true. Pointing back at an engine left behind that way reverts TargetAlreadyAttached. Too little destGasOverhead fails inbound messages with TokenHandlingError(token, 0x).

## Reference

- Script: [`script/configure/policy-engine/SetPolicyEngine.s.sol`](../../../script/configure/policy-engine/SetPolicyEngine.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
