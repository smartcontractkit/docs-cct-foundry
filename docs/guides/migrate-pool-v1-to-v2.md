---
type: guide
---

# Migrate a pool from v1 to v2

Migrating a registered token from an older pool version to a newer one moves the token's cross-chain
handling to the new pool without dropping in-flight messages.

## The workflow

Dual-remote registration exists from pool version **1.5.1**. A 1.5.0 pool holds one remote pool per chain,
so step 3 below is not performable there and that pool must be migrated by a direct cutover instead.

1. Deploy the new pool for the token, and grant it mint and burn rights **before** the cutover. Both
   pools hold the rights during the migration; this dual-role window is expected, and the old pool's
   rights are revoked only after the drain in step 6.
2. Optionally throttle the old pool's outbound on the migrating lane to slow new traffic through it
   (`isEnabled: true`, a token-sized `capacity`, `rate: 1`). Do **not** disable the limiter: a disabled
   bucket stops inbound releases too, and in-flight messages still need to land. Note that
   `UpdateRateLimiters` resolves any direction you leave unset from the declared `lanes{}` policy, so
   setting only `OUTBOUND_*` does not leave inbound untouched: it rewrites inbound from the declaration.
   To change outbound alone, either set `INBOUND_*` to inbound's current value in the same call, or make
   sure the declared policy already matches the on-chain inbound bucket.
3. Keep BOTH the old and the new remote pool addresses active on each lane while in-flight messages
   complete, so a message committed against the old pool can still be released. This needs a payload
   carrying both addresses, which is the JSON input mode (`VIA_JSON_FILE=true`) of `ApplyChainUpdates`:
   the inline env path takes a single remote pool and cannot express `[old, new]`. Set both in
   `script/input/apply-chain-updates.json`, whose `destPools` field is an array
   (`"destPools": ["0xOld", "0xNew"]`); a working example ships at that path. Do not remove the old one
   yet.
4. Repoint the registration: `SetPool` the token's `TokenAdminRegistry` entry at the new pool. New
   messages now route through the new pool.
5. Validate end to end: one transfer per directed lane, confirmed on the destination.
6. After the in-flight drain window, remove the old remote pool. The window ends when every message
   inbound for this token reads `SUCCESS`, once per remote the pool serves, **plus a margin** past the
   lane's maximum source finality, because the index lags the source chain and a message sent shortly
   before the query can be invisible to it. Waiting longer costs nothing. See [Remove a remote
   pool](../operations/lanes-and-remotes.md#remove-a-remote-pool) for the gate and what to do when it does
   not clear. This step is optional, and deferring it indefinitely is a valid choice, because a pool that
   is out of the `TokenAdminRegistry` is already inert.

The removal in step 6 is per peer, not per pool: every pool that registered this chain's old pool has to
drop it too, so the blast radius grows with the number of remotes.

> [!warning] Re-applying a chain update REPLACES the chain's whole entry, so it can silently drop the old
> remote pool that step 3 deliberately kept, or undo the step 2 throttle. See [Apply chain
> updates](../operations/lanes-and-remotes.md#apply-chain-updates).

**Before the cutover, pre-stage the rollback.** Rolling back is not a single `SetPool`: the old pool must
still recognise the current remotes on every peer, hold its rate limits, and be re-registered wherever it
was dropped, and a rollback reopens old-pool traffic so the drain gate has to be re-run afterwards.
Deciding all of that during an incident is what makes rollbacks fail.

This is composed from existing primitives (`SetPool` and the remote-pool management scripts, in the
`token-admin-registry` and `remote-pools` groups of the [primitives catalog](../primitives/index.md)); it
is not a single template command.

## Honest scoping

The template's deploy scripts pin the pool version, so deploying two coexisting pool versions for the same
token through the deploy path is not reachable today. See the
[pinned-pool-version gotcha](../gotchas/index.md#pool-version-pinned). The migration above is therefore
performed against a pool you deploy and manage yourself, using the wiring primitives, rather than through
a template migration command.

## Version behavior differs

An older pool does not behave identically to the v2.0 default. Rate-limit validation, decimals handling,
and the pause pattern all differ by version. Read the per-version behavior matrix in
[pool behavior matrix](../reference/pool-behavior-matrix.md) (the rate-limit-validation, decimals, and
pause rows) before and after the cutover, keyed off each pool's `typeAndVersion`, so the rate limits and
pause behavior you set mean what you expect on both the old and the new pool.
