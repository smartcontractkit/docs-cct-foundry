---
type: reference
---

# Policy engine

> After applying a change here, sync your declared source of truth (the project store) and reconcile it
> against live with `make doctor CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).
> For this page specifically the sync command is `make snapshot-chain CHAIN=<chain>`: `hooks.policyEngine`
> is a governance-critical `roles{}` field, and the old declaration fails `make roles-check` until it is
> re-snapshotted.

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

## Before you set an engine

Two preconditions must hold before the swap lands, or every transfer on the affected lanes stops:

- **Provision the engine for this hooks address first.** Extractors, policies, and the per-target
  default all live on the engine, keyed by the hooks address; nothing carries over from the old
  engine. With the ACE default of reject, an unprovisioned engine rejects every `ccipSend` from the
  moment the swap lands (`PolicyRunRejected`). Provision the new engine (extractor, policies,
  `setTargetDefaultPolicyAllow`) while the old engine (or none) is still attached, then swap.
- **Budget `destGasOverhead` for `postflightCheck` on every lane into this chain.** `postflightCheck`
  runs inside `releaseOrMint` on the destination, within the gas the source pool quotes as
  `destGasOverhead` for that lane. The FeeQuoter default is 90,000, and one policy alone can exceed it
  (a local measurement of one `VolumePolicy` in `postflightCheck` runs ~97,000 gas; a live run with
  Sanctions, KYC and Volume policies measured ~217,000). A short budget ends in an out-of-gas inside
  the pool call, and the message goes to FAILURE with `TokenHandlingError(token, 0x)` (empty bytes,
  unlike a real policy rejection, which carries `PolicyRunRejected`) and needs a manual execution.
  Raise it on the source pool of every lane into the engine's chain with
  [`UpdateTokenTransferFeeConfig`](fees.md) (`DEST_GAS_OVERHEAD=360000`, `DEST_BYTES_OVERHEAD` of at
  least 32), and declare it in `lanes.<remote>.v2.feeConfig`. The larger overhead is charged to the
  sender.

Also note the ACE version difference: from ACE 1.1.1 the engine's `run()` reverts `TargetNotAttached`
for a target that is not attached, while 1.0.0 does not gate on it. A local test against 1.0.0 can
therefore pass a flow a live 1.1.1+ engine rejects.

## Set the policy engine

Point the hooks at the engine deployed on the same chain. The hook calls `attach()` on the engine,
which starts ACE target detection. Only the hooks owner can call `setPolicyEngine`; when a Safe owns
the hooks, run it with `MODE=safe` (see [governance modes](../governance-modes.md)).

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

The script refuses two inputs before broadcasting: a same-address update (a silent no-op on the hook
that would report success) and an engine address with no code on this chain (the hook's `attach()` call
would revert with empty data).

`setPolicyEngine` detaches the old engine first and reverts `PolicyEngineDetachReverted` when the old
engine's `detach()` reverts. The recovery path is the same script with `ALLOW_FAILED_DETACH=true`,
which calls `setPolicyEngineAllowFailedDetach` on the hook:

```bash
POOL_HOOKS=0x... \
  POLICY_ENGINE=0x... \
  ALLOW_FAILED_DETACH=true \
  forge script \
  script/configure/policy-engine/SetPolicyEngine.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

The old engine keeps the hook listed as attached after a forced move, so pointing back at it later
reverts `TargetAlreadyAttached` until that engine drops the hook.

After the swap, re-snapshot the declared roles: `make snapshot-chain CHAIN=<chain>` records
`hooks.policyEngine` in `roles{}`. Until then, `make roles-check` reports the moved governance slot,
which the [roles runbook](../roles.md#the-drift-response-runbook) says to treat as a potential
compromise.

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
