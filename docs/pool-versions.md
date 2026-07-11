# Pool versions: how this repo decides what to call

Every TokenPool operation in this repo is dispatched on the pool's contract version. This page is
the doctrine behind that dispatch and the reference the error messages point at. The machine-readable
catalog lives in [`src/PoolVersions.sol`](../src/PoolVersions.sol); the on-chain resolver lives in
[`script/utils/PoolVersion.s.sol`](../script/utils/PoolVersion.s.sol). The same catalog gates the
adoption of externally deployed pools; see
[`enabling-existing-token.md`](enabling-existing-token.md).

## The key is the contract's own word

The version of a pool is what its on-chain `typeAndVersion()` reports, parsed into an ordered
catalog. It is never inferred from:

- **npm package versions.** They do not identify pool contracts: the npm
  `@chainlink/contracts-ccip@1.6.0` package ships pools stamped `1.5.1`.
- **Capability probes.** Trying a call and classifying by whether it reverts conflates "the function
  does not exist" with "the function reverted for a state reason" and with "the RPC hiccuped", and a
  getter's presence never proves a setter's shape.

An address with no `typeAndVersion()` at all (a token passed where a pool was expected, an EOA, an
undeployed address) is refused with `NotACcipTokenPool` before any version reasoning starts.

## The catalog

```
UNKNOWN < 1.5.0 < 1.5.1 < 1.6.1 < 2.0.0
```

- `UNKNOWN` is the zero-value sentinel: a default-initialized version can never dispatch.
- There is no `1.6.0` pool in the wild; the audited 1.6-generation stamp is `1.6.1`.
- The `1.6.2`-`1.6.4` source tags stamp `-dev` strings (`1.6.3-dev`, `1.6.x-dev`); they are
  unaudited development builds and are refused (see [dev builds](#dev-builds)).

<a id="operation-ranges"></a>

## Support is a range, not a floor

Pool ABIs remove functions as well as add them. `2.0.0` dropped `setChainRateLimiterConfig`,
`setRouter`, `setRateLimitAdmin`, and pool-level `applyAllowListUpdates` while introducing
`setRateLimitConfig`, `setDynamicConfig`, and the hooks/fee/finality surface. So every dispatched
operation declares a half-open range `[introducedIn, removedIn)` in ONE central table
(`PoolVersions.opRange`), and call sites gate through `PoolVersions.requireSupports`. An "at least
version X" check is never written at a call site. A call outside the range refuses with
`UnsupportedPoolOperation`, naming the pool, its contract version, and the versions the operation
exists on.

| Operation                            | Range                |
| ------------------------------------ | -------------------- |
| `applyChainUpdates` (modern shape)   | `[1.5.1, infinity)`  |
| `applyChainUpdates` (1.5.0 shape)    | `[1.5.0, 1.5.1)`     |
| `addRemotePool` / `removeRemotePool` | `[1.5.1, infinity)`  |
| `getRemotePools` (plural)            | `[1.5.1, infinity)`  |
| `getRemotePool` (singular)           | `[1.5.0, 1.5.1)`     |
| `setChainRateLimiterConfig`          | `[1.5.0, 2.0.0)`     |
| `setRateLimitConfig`                 | `[2.0.0, infinity)`  |
| `setRouter` / `setRateLimitAdmin`    | `[1.5.0, 2.0.0)`     |
| `setDynamicConfig`                   | `[2.0.0, infinity)`  |
| `applyAllowListUpdates` (pool-level) | `[1.5.0, 2.0.0)`     |

The table in `src/PoolVersions.sol` is authoritative; this rendering mirrors it for reading.

The catalog and ranges are validated live, not only against source: every cataloged version
(1.5.0, 1.5.1, 1.6.1, 2.0.0) was exercised against real testnet pools of that version through the
repo scripts (adoption, lane updates including the 1.5.0 encoding, rate-limit updates, read-backs),
including end-to-end cross-chain token transfers per version in both directions over the same lane.

<a id="unknown-versions"></a>

## Unknown versions: writes refuse, reads degrade

A version the catalog does not know (a future release, a fork's vanity string) means STOP for
anything that broadcasts a transaction: the scripts refuse with `UnsupportedPoolVersion` rather than
guess a calldata shape. Best-effort dispatch against the wrong shape either reverts raw on-chain
(the least diagnosable failure) or, worse, succeeds with the wrong semantics.

Read-only scripts that dispatch version-shaped reads (`GetRemotePools`, `GetSupportedChains`,
`GetCurrentRateLimits` and similar) never refuse: they print a warning
(`WARN: unrecognized pool version "..."; read-only display, best effort.`) and continue with
best-effort getters. Diagnostics must survive unknown versions; a broadcast must not.

If a pool reports a version like `1.6.0` that you expected to exist, you are probably reading an
npm package version; see [the key is the contract's own word](#the-key-is-the-contracts-own-word).
If a genuinely new pool release appears, extend the catalog: see
[adding a version](#adding-a-version). For an immediate, deliberate exception, use the
[override](#overrides).

<a id="pool-types"></a>

## Foreign pool types

Version tokens are only comparable within the standard TokenPool lineage: `BurnMintTokenPool`,
`BurnFromMintTokenPool`, `BurnWithFromMintTokenPool`, `LockReleaseTokenPool`. Specialized pools
(for example `USDCTokenPool`) version independently; their `1.5.1` is not TokenPool `1.5.1` and
must not dispatch as such. The resolver refuses any type prefix outside the lineage with
`UnsupportedPoolType`. If you have verified a foreign pool's ABI against a cataloged version, the
[override](#overrides) applies.

<a id="dev-builds"></a>

## Dev builds

A `-dev` version suffix marks an unaudited development build with no stable ABI; the resolver
refuses it for dispatch and for adoption with `DevBuildRefused`. A dev build straddles version
boundaries by definition, so no static mapping to a released version is assumed. If you operate
such a pool and have verified its ABI per axis, assert it explicitly with the
[override](#overrides).

<a id="overrides"></a>

## POOL_VERSION_OVERRIDE

The escape hatch for dev builds, forks, and not-yet-cataloged releases:

```
POOL_VERSION_OVERRIDE=0xPoolAddress=2.0.0
```

- **Address-scoped.** The entry applies to exactly one pool; other pools resolve normally.
  Multiple entries are comma-separated: `0xA...=1.6.1,0xB...=2.0.0`. A malformed entry anywhere in
  the specification aborts with `PoolVersionOverrideMalformed`, on read and write paths alike.
- **Cataloged targets only.** The asserted version must be one of `1.5.0`, `1.5.1`, `1.6.1`,
  `2.0.0`; the assertion means "this pool's ABI profile matches that cataloged version".
- **Cross-checked.** Before the override is honored, the resolver asserts the claim against the
  pool's actual surface: a claim of `2.0.0` or later must answer the v2 getter
  `getCurrentRateLimiterState(uint64,bool)`; an earlier claim must answer the v1 getter
  `getCurrentOutboundRateLimiterState(uint64)`. A disagreement aborts with
  `PoolVersionOverrideMismatch`, naming both facts.
- **Loud.** Every honored override prints a banner with the pool, the true on-chain string, and
  the version applied.
- **Per invocation.** Set it on the command line for the one run that needs it. Do not put it in
  `.env`, CI configuration, a Makefile, or a README snippet; a standing override defeats the
  deliberate-exception property.
- **Provenance is never aliased.** Adoption (`AdoptToken`) records the TRUE on-chain
  `typeAndVersion()` string in the address registry; the override shows only in the console
  output of the run that used it.

## What this doctrine does NOT cover

- **The deploy-time equality guard.** `DeployBurnMintTokenPool` / `DeployLockReleaseTokenPool`
  assert the deployed contract's `typeAndVersion()` equals the expected exact string. That is a
  pinned-dependency check, not dispatch; converting it to a range comparison would destroy its
  point. It stays an exact string.
- **Registry keying.** The address registry keys pool entries by the full on-chain
  `typeAndVersion()` string as a provenance record. Enum ordinals are never persisted or logged;
  they can shift when a version is inserted mid-catalog.

## Adding an operation

1. Verify the operation's per-version presence and signature against the tagged pool sources
   (compute the selector with `cast sig`).
2. Add the `Op` enum member and its `[introducedIn, removedIn)` row in `PoolVersions.opRange`,
   with the name in `opName`.
3. Gate the call site with `PoolVersions.requireSupports` before building calldata; switch on the
   version only where the calldata shape or target differs per version.
4. Add the operation's expected row to the table-driven test in
   `test/actions/PoolVersionDispatch.t.sol` (its count assertion fails until you do) and mirror
   the row in this page's table.

## Adding a version

1. Verify the new release's pool ABI against the tagged source, not the npm package.
2. Insert the `Version` enum member in order and extend `fromVersionToken` / `toString`.
3. Fill the new version's cell in EVERY row of `opRange`, and extend every version-switch call
   site (the lane-update switch in `ApplyChainUpdates` reverts on an unhandled cataloged version
   rather than falling through).
4. Extend the expected matrix in `test/actions/PoolVersionDispatch.t.sol` (the version-count
   assertion fails until you do) and update this page.
