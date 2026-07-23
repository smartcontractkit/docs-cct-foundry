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

## Keystore password (non-interactive runs)

The deploy steps sign with a Foundry keystore selected by `--account`, so `make deploy-token` and
`make deploy-pool` prompt for the keystore passphrase on the terminal. For CI or any non-interactive run,
set Foundry's native `ETH_PASSWORD` (the env form of `--password-file`) to a **file path** whose contents
are the passphrase: an **empty file** for a passwordless keystore, or a file holding the passphrase for a
protected one.

```bash
set -a && . ./.env && set +a          # the deploy recipe reads the chain's RPC env var, so export .env
PW=$(mktemp)                          # empty file = empty passphrase (a passwordless keystore)
# for a password-protected keystore instead: printf '%s' '<passphrase>' > "$PW"
ETH_PASSWORD="$PW" make deploy-token CHAIN=<chain> KEYSTORE_NAME=<account> VERIFY=1 </dev/null
```

`ETH_PASSWORD` is a file **path**, not the passphrase itself (`ETH_PASSWORD=""` is rejected as a missing
file). Without it, a non-interactive run cannot reach the terminal prompt and Foundry falls back to its
default sender, so pass it (or run the target interactively).

Treat the password file as a secret: keep it out of the repo, restrict it (`chmod 600`), and prefer an
ephemeral file (`mktemp`, removed after the run). The keystore itself stays encrypted; the file only holds
its passphrase. This non-interactive path is for CI and testnet automation. For a **production or
high-value signer**, prefer a hardware wallet (`--ledger` / `--trezor`) over any automatable password, per
[keystore signing](../decisions/0001-keystore-signing.md).
