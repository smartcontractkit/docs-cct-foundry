---
type: workflow
---

# Greenfield deploy

Deploy a new BurnMint token cross-chain end to end. Run the five steps on EACH chain (swapping the local
and remote chain), then send a transfer. The machine-executable wiring is in
[`greenfield-deploy.arazzo.json`](greenfield-deploy.arazzo.json).

## Steps

1. [`DeployToken`](../primitives/deploy/DeployToken.md) - deploy the token. Output: the token address,
   recorded in the project store.
2. [`DeployBurnMintTokenPool`](../primitives/deploy/DeployBurnMintTokenPool.md) - deploy its pool
   (resolves the token from the registry). Output: the pool address.
3. [`ClaimAndAcceptAdmin`](../primitives/token-admin-registry/ClaimAndAcceptAdmin.md) - register the token
   admin (auto-detects the claim path). One atomic step: see [composition](../concepts/composition.md).
4. [`SetPool`](../primitives/token-admin-registry/SetPool.md) - point the TokenAdminRegistry at the pool.
5. [`ApplyChainUpdates`](../primitives/token-admin-registry/ApplyChainUpdates.md) - wire the lane to the
   remote chain (remote pool plus rate limits).

Then [send and track a transfer](../guides/send-track-diagnose.md). See the copy-pasteable commands in the
[README quick start](../../README.md#quick-start) and the per-operation pages under
[operations](../operations/tokens.md).

## Mode

`mode=eoa` (default) broadcasts each step. `mode=safe` emits one Safe batch for the register, set-pool, and
wire steps to sign once; the deploy steps sign with the keystore in both modes. See
[governance modes](../governance-modes.md).
