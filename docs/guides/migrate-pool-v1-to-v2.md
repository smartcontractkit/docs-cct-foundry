---
type: guide
---

# Migrate a pool from v1 to v2

Migrating a registered token from an older pool version to a newer one moves the token's cross-chain
handling to the new pool without dropping in-flight messages.

## The workflow

1. Deploy the new pool for the token.
2. Keep BOTH the old and the new remote pool addresses active on each lane while in-flight messages
   complete, so a message committed against the old pool can still be released. Add the new remote pool
   with the remote-pool management primitives; do not remove the old one yet.
3. Repoint the registration: `SetPool` the token's `TokenAdminRegistry` entry at the new pool. New
   messages now route through the new pool.
4. After the in-flight drain window, remove the old remote pool from each lane.

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
