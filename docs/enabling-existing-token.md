---
type: guide
---

# Enabling an existing token

The [README quick start](../README.md#quick-start) assumes this repo deploys both the token
and the pool. This page covers the two other starting points: a token that already exists on chain,
and a token plus pool that were both deployed by other tooling. In both cases the goal is the same:
get the contracts into the [deployed-address registry](deployed-addresses.md) so every later script
resolves them with zero exports, then continue with the standard setup and day-2 operations.

| You have                                      | Path                                                                                    |
| --------------------------------------------- | --------------------------------------------------------------------------------------- |
| An existing token, no CCIP pool               | [Scenario 1](#scenario-1-existing-token-no-pool): adopt the token, deploy a pool for it |
| An existing token AND pool from other tooling | [Scenario 2](#scenario-2-existing-token-and-pool): adopt both, run day-2 operations     |

Both paths run through `make adopt-token`, which validates everything on chain before writing a
single registry entry (see [what adopt-token validates](#what-adopt-token-validates)).

## Scenario 1: existing token, no pool

1. Adopt the token into the registry:

   ```bash
   make adopt-token CHAIN=ethereum-testnet-sepolia TOKEN=0xYourToken
   ```

   `CHAIN` is the canonical selectorName (the `config/chains/<name>.json` basename, which is also the
   project-store basename). The command probes the token's registration path and records it in the
   `addresses{}` subtree of `project/<selectorName>.json`; from here on, scripts resolve `TOKEN` from the
   registry with no `export`. For a non-EVM chain, adopt base58 values instead:
   `make adopt-token CHAIN=<solana-chain> TOKEN_B58=<base58> [POOL_B58=<base58>]`.

2. Deploy a pool for it, following [operations: pools](operations/pools.md)
   (BurnMint if you hold mint/burn rights on the token, LockRelease plus lockbox otherwise). The
   deploy resolves the adopted token from the registry and records the pool the same way.

3. Register and wire, following [operations: registration](operations/registration.md):
   `ClaimAdmin`, `AcceptAdminRole`, `ApplyChainUpdates`, `SetPool`. All of them resolve the token
   and pool from the registry.

## Scenario 2: existing token and pool

When another toolchain (or an earlier version of this repo) deployed both contracts, adopt them
together:

```bash
make adopt-token CHAIN=ethereum-testnet-sepolia TOKEN=0xYourToken TOKEN_POOL=0xYourPool
```

The pool is resolved through the [pool-version catalog](pool-versions.md) and cross-checked against
the token before anything is written. After a successful adoption the day-2 scripts work with zero
exports, exactly as if this repo had deployed the contracts. The command prints the next steps that
still apply to your token: registration (`ClaimAdmin` + `AcceptAdminRole`) if the token is not
registered yet, `SetPool` if the TokenAdminRegistry does not point at this pool, lane wiring, and
`make doctor CHAIN=<name>`.

A typical day-2 sequence after adopting on both chains (each command resolves `TOKEN` /
`TOKEN_POOL` from the registry; pass them inline only to override):

```bash
# register the token (skip if already registered)
forge script script/setup/ClaimAdmin.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
forge script script/setup/AcceptAdminRole.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast

# point the TokenAdminRegistry at the adopted pool
forge script script/setup/SetPool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast

# wire the lane to the remote chain's pool and token, with outbound/inbound rate limits
DEST_CHAIN=AVALANCHE_TESTNET_FUJI \
  DEST_TOKEN_POOL=0xRemotePool \
  DEST_TOKEN=0xRemoteToken \
  OUTBOUND_RATE_LIMIT_CAPACITY=100000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=100000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script script/setup/ApplyChainUpdates.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast

# read back the configured rate limits
DEST_CHAIN=AVALANCHE_TESTNET_FUJI \
  forge script script/configure/rate-limiter/GetCurrentRateLimits.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

Declare the lane in the chain config too (`make add-lane LOCAL=<a> REMOTE=<b> CAPACITY=<wei>
RATE=<wei> [BOTH=1]`), so `make doctor` can prove mesh reciprocity; see
[config-architecture.md](config-architecture.md#command-reference).

## What adopt-token validates

Validation happens on chain BEFORE anything is written; a failed probe refuses the adoption and
writes nothing. What each check and refusal means:

| Check                                               | On failure                                                                                   |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| The token address has contract code                 | `no contract code at token 0x...`: wrong address or wrong chain                              |
| Registration path: `getCCIPAdmin()`, then `owner()` | Neither answers: a WARN, not a refusal (see below)                                           |
| The pool address has contract code (when given)     | `no contract code at pool 0x...`                                                             |
| The pool reports a cataloged contract version       | A named refusal from the resolver: see [version gating](#version-gating-at-adoption)         |
| The pool's `getToken()` equals `TOKEN`              | `pool/token mismatch: pool 0x... manages 0x..., not 0x...`: the pool binds a different token |
| TokenAdminRegistry state read-back                  | Never refuses; reports administrator, pending administrator, and registered pool             |

Two of the read-backs are warnings by design:

- **Token exposes neither `getCCIPAdmin()` nor `owner()`.** Self-registration through the
  `RegistryModuleOwnerCustom` is unavailable, so `ClaimAdmin` cannot register this token. Adoption
  still proceeds: the token may already be registered in the TokenAdminRegistry, or registration
  may happen through another path.
- **The TokenAdminRegistry already points at a different pool.** The adopted pool is recorded, and
  `SetPool` is the step that moves the on-chain registration.

## Zero-export resolution after adoption

Adoption writes the same registry entries a deploy writes: `deployments` entries keyed by symbol
(the pool key carries its full on-chain `typeAndVersion()` string) plus the `active.<role>`
pointers. Every later script resolves `active.token` / `active.tokenPool` automatically.

`active.<role>` is single-valued per chain: adopting a second token repoints `active.token` at it
(the command warns when it does), and the previous token must then be passed explicitly
(`TOKEN=0x...` inline or the chain-scoped export). The full precedence and the two-store model are
in [deployed-addresses.md](deployed-addresses.md).

## Version gating at adoption

An adopted pool goes through the same version resolver every dispatched operation uses, so an
adoption can be refused with any of the resolver's named errors: `NotACcipTokenPool` (the address
has no `typeAndVersion()`, for example the token address passed as `TOKEN_POOL`),
`UnsupportedPoolType` (a specialized pool outside the standard TokenPool lineage),
`DevBuildRefused` (a `-dev` build with no stable ABI), or `UnsupportedPoolVersion` (a version the
catalog does not know). Each message explains the failure and links the matching section of
[pool-versions.md](pool-versions.md).

`POOL_VERSION_OVERRIDE` is honored at adoption with its usual cross-check and banner:

```bash
POOL_VERSION_OVERRIDE=0xYourPool=1.6.1 make adopt-token CHAIN=ethereum-testnet-sepolia TOKEN=0xYourToken TOKEN_POOL=0xYourPool
```

The registry always records the TRUE on-chain `typeAndVersion()` string; the override version never
leaks into the registry. See [pool-versions.md](pool-versions.md#overrides).

## Pool version migration

Moving a registered token from an older pool version to a newer one (deploy the new pool, keep both
remote pool addresses active while in-flight messages complete, repoint the registration, then
remove the old remote) is composed from the individual primitives:
`SetPool`, and the remote-pool management scripts described in the
[operations: lanes and remote pools](operations/lanes-and-remotes.md).