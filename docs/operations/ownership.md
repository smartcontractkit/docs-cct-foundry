---
type: reference
---

# Ownership and admin handoff

> After moving an authority here, sync your declared `roles{}` source of truth (`make snapshot-chain`) and
> reconcile it against live with `make roles-check CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).

Hand off control of a deployment to a multisig or a different EOA after initial setup. These scripts are
not required for the core deployment flow. Three distinct authorities move through three different
scripts, so pick by what you are moving:

- Transfer ownership: moves the `owner` of a pool, pool hooks, or lock box.
- Transfer token admin: moves a token's internal top-level admin (`defaultAdmin` / `owner` /
  `DEFAULT_ADMIN_ROLE`).
- Transfer token admin role: moves the TokenAdminRegistry administrator, the CCIP registry authority that
  controls a token's pool cutover.

Scripts under `script/setup/transfer-ownership/`, `script/setup/token-roles/`, and `script/setup/`.
Primitive pages: [`TransferOwnership`](../primitives/ownership/TransferOwnership.md),
[`AcceptOwnership`](../primitives/ownership/AcceptOwnership.md),
[`TransferTokenAdmin`](../primitives/token-roles/TransferTokenAdmin.md),
[`TransferTokenAdminRole`](../primitives/token-admin-registry/TransferTokenAdminRole.md). For the full
EOA-to-Safe ceremony see [Roles](../roles.md#the-eoa--safe-handoff-ceremony).

## Transfer ownership (pool, hooks, or lock box)

Initiates a two-step ownership transfer for any Ownable contract (a token pool, pool hooks, or a lock
box). It takes `ADDRESS` (the contract) and `NEW_OWNER`, treats the contract as a generic `IOwnable`, and
labels its console output from the contract's `typeAndVersion()` when it exposes one. These contracts use
Chainlink's `ConfirmedOwner` two-step pattern, so the transfer always requires `AcceptOwnership` to
complete.

This is a generic Ownable transfer. To move a token's top-level admin, use
[Transfer token admin](#transfer-token-admin) instead: it is template-aware. A token that exposes no
`owner()` (a crosschain or burnmint token) reverts here with a pointer to that script.

Step 1, initiate (run as the current owner):

```bash
ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast
```

Step 2, accept (run as `NEW_OWNER`):

```bash
ADDRESS=0xYourPool \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast
```

## Transfer token admin

Moves a token's internal top-level admin (its `defaultAdmin` / `owner` / `DEFAULT_ADMIN_ROLE`) with
`script/setup/token-roles/TransferTokenAdmin.s.sol`. The script auto-detects the token template and picks
the correct mechanism: a native two-step transfer for crosschain (`AccessControlDefaultAdminRules`) and
factory (`Ownable2Step`) tokens (initiate here, then the new admin runs the same script with `ACCEPT=1`),
and a grant-only `grantRole(DEFAULT_ADMIN_ROLE, NEW_ADMIN)` for burnmint (plain `AccessControl`) tokens.
For a burnmint token, the grant leaves the old holder's `DEFAULT_ADMIN_ROLE` in place; a full handoff is
that grant followed by `RevokeTokenRole` (`ROLE=defaultAdmin`), run by the new admin, to remove the old
holder.

```bash
# Burnmint token: grant DEFAULT_ADMIN_ROLE to the new admin (grant-only)
NEW_ADMIN=0xNewAdmin \
  forge script \
  script/setup/token-roles/TransferTokenAdmin.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast
```

## Transfer token admin role

Initiates a transfer of the CCIP token admin role (the TokenAdminRegistry administrator) to a new
address. This is step 1 of a two-step process; the new admin must run `AcceptAdminRole` to complete it.

```bash
NEW_ADMIN=0xNewAdminAddress \
  forge script \
  script/setup/TransferTokenAdminRole.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Set `TOKEN=0x...` to override the token address (defaults to the `{CHAIN}_TOKEN` env var).
