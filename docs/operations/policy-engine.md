---
type: reference
---

# Policy engine

> After applying a change here, sync your declared source of truth (the project store) and reconcile it
> against live with `make doctor CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).

Connect an `AdvancedPoolHooks` contract to a [Chainlink ACE](https://docs.chain.link/ace) Policy Engine
on the same chain, or disconnect the engine. Scripts under `script/configure/policy-engine/`. Primitive
pages: [`SetPolicyEngine`](../primitives/policy-engine/SetPolicyEngine.md),
[`GetPolicyEngine`](../primitives/policy-engine/GetPolicyEngine.md).

The hook forwards each transfer to the engine for evaluation before the source pool locks or burns
tokens (`preflightCheck`) and before the destination pool releases or mints tokens
(`postflightCheck`). If a policy rejects the call, the hook reverts and the transfer does not proceed.
For the Platform-side workflow (target detection, the built-in `CCIP-AdvancedPoolHooks` contract type,
policy instances, protections, and extractor mappings), see
[Protect CCIP Token Pools with ACE](https://docs.chain.link/ace/guides/policy-manager/ccip-token-pools).

## Set the policy engine

Point the hooks at the engine deployed on the same chain. The hook calls `attach()` on the engine,
which starts ACE target detection. Only the hooks owner can call `setPolicyEngine`.

```bash
POOL_HOOKS=0x... \
  POLICY_ENGINE=0x... \
  forge script \
  script/configure/policy-engine/SetPolicyEngine.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

The zero address disconnects the engine and stops policy checks:

```bash
POOL_HOOKS=0x... \
  POLICY_ENGINE=0x0000000000000000000000000000000000000000 \
  forge script \
  script/configure/policy-engine/SetPolicyEngine.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

`setPolicyEngine` detaches the old engine first and reverts `PolicyEngineDetachReverted` when the old
engine's `detach()` reverts. The on-chain recovery path for that case is
`setPolicyEngineAllowFailedDetach` on the hook itself. A same-address update is a no-op on the hook, so
the script refuses it before broadcasting.

## Get the policy engine

Reads the engine address currently set on the hooks contract, or reports that none is set (policy
checks disabled).

```bash
POOL_HOOKS=0x... \
  forge script \
  script/configure/policy-engine/GetPolicyEngine.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```
