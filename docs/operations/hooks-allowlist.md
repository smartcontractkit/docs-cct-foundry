---
type: reference
---

# Advanced Pool Hooks, allowlist, and authorized callers

> After applying a change here, sync your declared source of truth (the project store) and reconcile it
> against live with `make doctor CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).

Deploy and wire the `AdvancedPoolHooks` contract, manage its allowlist, and manage the authorized
callers on hooks and lock boxes. Scripts under `script/configure/allowlist/` and
`script/configure/authorized-callers/`. Primitive pages:
[`DeployAdvancedPoolHooks`](../primitives/allowlist/DeployAdvancedPoolHooks.md),
[`GetAdvancedPoolHooks`](../primitives/allowlist/GetAdvancedPoolHooks.md),
[`UpdateAdvancedPoolHooks`](../primitives/allowlist/UpdateAdvancedPoolHooks.md),
[`UpdateAllowList`](../primitives/allowlist/UpdateAllowList.md),
[`GetAllowList`](../primitives/allowlist/GetAllowList.md),
[`IsAllowListed`](../primitives/allowlist/IsAllowListed.md),
[`UpdateAuthorizedCallers`](../primitives/authorized-callers/UpdateAuthorizedCallers.md),
[`GetAuthorizedCallers`](../primitives/authorized-callers/GetAuthorizedCallers.md).

## Deploy Advanced Pool Hooks

Use this for enhanced security features like allowlists, CCV management, policy engine integration, and
threshold-based validation. Configure defaults in `script/input/advanced-pool-hooks.json` (see [Config
and project-store schema](../config-schema.md)), or override any field with an environment variable.

| Env var              | Type              | Default (from `advanced-pool-hooks.json`) |
| -------------------- | ----------------- | ----------------------------------------- |
| `ALLOWLIST`          | CSV or JSON array | `.allowlist`                              |
| `AUTHORIZED_CALLERS` | CSV or JSON array | `.authorizedCallers`                      |
| `THRESHOLD_AMOUNT`   | uint256           | `.thresholdAmount`                        |
| `POLICY_ENGINE`      | address           | `.policyEngine`                           |
| `POOL_TYPE`          | string            | `BurnMint` (or `LockRelease`)             |

The `allowlistEnabled` flag is set immutably at deploy time based on whether `ALLOWLIST` is non-empty. If
you deploy with an empty allowlist (the default), allowlist functionality is permanently disabled and
later calls to `UpdateAllowList` always revert. To enable allowlisting, pass at least one address via
`ALLOWLIST` at deploy time. There is no setter to flip this later: to switch allowlisting on or off you
must deploy a new `AdvancedPoolHooks` with the flag you want and re-point the pool at it with
`UpdateAdvancedPoolHooks`. `UpdateAllowList` only edits the entries of an already-enabled allowlist; it
cannot turn the feature on.

```bash
forge script \
  script/configure/allowlist/DeployAdvancedPoolHooks.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

The hooks address is saved to
`history/advanced-pool-hooks/{selectorName}/{timestamp}-AdvancedPoolHooks.json` under the `POOL_HOOKS`
key. Then pass the hooks address as `POOL_HOOKS` when [deploying a token pool](pools.md), or connect it
to an existing pool below.

## Get Advanced Pool Hooks

Reads the `AdvancedPoolHooks` contract address currently attached to a token pool.

```bash
forge script script/configure/allowlist/GetAdvancedPoolHooks.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

## Connect Advanced Pool Hooks to a token pool

```bash
TOKEN_POOL=0x... \
  NEW_HOOK=0x... \
  forge script \
  script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

## Manage the allowlist

Supports CSV or JSON array. If `POOL_HOOKS` is not set, the script falls back to calling directly on the
`TOKEN_POOL` (v1 pools only).

```bash
# Add addresses via AdvancedPoolHooks
POOL_HOOKS=0x... \
  ADD_ADDRESSES="0xAAA...,0xBBB..." \
  forge script \
  script/configure/allowlist/UpdateAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove addresses
POOL_HOOKS=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/allowlist/UpdateAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

View the current allowlist:

```bash
POOL_HOOKS=0x... \
  forge script \
  script/configure/allowlist/GetAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```

Check whether an address is allowlisted:

```bash
POOL_HOOKS=0x... \
  CHECK_ADDRESS=0x... \
  forge script \
  script/configure/allowlist/IsAllowListed.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```

## Manage authorized callers

`AuthorizedCallers` is used in two places:

- `AdvancedPoolHooks`: authorized callers are the token pools permitted to invoke the hooks.
- `ERC20LockBox`: authorized callers are the `LockReleaseTokenPool` contracts permitted to call
  `deposit`/`withdraw`.

Both use the same scripts, passing either `POOL_HOOKS=<hooksAddress>` or `LOCK_BOX=<lockBoxAddress>`.
Supports CSV or JSON array.

```bash
# Add callers - AdvancedPoolHooks
POOL_HOOKS=0x... \
  ADD_ADDRESSES="0xAAA...,0xBBB..." \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Add callers - ERC20LockBox
LOCK_BOX=0x... \
  ADD_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove callers - AdvancedPoolHooks
POOL_HOOKS=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove callers - ERC20LockBox
LOCK_BOX=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

View the current authorized callers:

```bash
# AdvancedPoolHooks
POOL_HOOKS=0x... \
  forge script \
  script/configure/authorized-callers/GetAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME

# ERC20LockBox
LOCK_BOX=0x... \
  forge script \
  script/configure/authorized-callers/GetAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```
