---
type: reference
---

# Pool-version behavior deltas

Beyond which config fields exist, a pool's runtime behavior differs by version, and an adopted older pool
behaves differently from the template's v2.0 default. Every row below is backed by a passing fixture that
exercises the real deployed bytecode of each version (a Sepolia fork), not a mock. Keyed off the pool's
`typeAndVersion`.

| Behavior | v1.5.0 | v1.5.1 | v1.6.x | v2.0 |
| --- | --- | --- | --- | --- |
| Mixed decimals | Not supported (mints the raw source amount 1:1) | Supported | Supported | Supported |
| Inbound rate limit metered on | raw source amount | un-rescaled source amount | rescaled local amount | rescaled local amount |
| Rate-limiter config validation (enabled) | `rate >= capacity` or `rate == 0` reverts | same as v1.5.0 | `rate > capacity` reverts (`rate == 0` allowed) | same as v1.6.x |
| Pause via `capacity=1, rate=1` | reverts (`1 >= 1`) | reverts | valid | valid |
| Fast-finality rate limiter | none | none | none | separate limiter; falls back to the standard bucket when disabled |
| Dedicated pause function | none | none | none | none (pause is the rate-limit throttle) |

## Pausing a pool, per version

A v2 pool has no dedicated pause or `Pausable` mechanism, so the reversible pause in both v1 and v2 is a
rate-limit throttle. The only hard stop is removing the chain, which tears the lane down rather than
pausing it (and carries a stale-config re-add gotcha), so it is the wrong tool for a temporary pause.

- On v1.6+ and v2.0, an enabled limiter with `capacity=0, rate=0` is a true zero-throughput block (every
  transfer reverts `TokenMaxCapacityExceeded`), cleaner than `capacity=1, rate=1`, which leaks one unit
  and refills.
- On v1.5.x this is impossible: the validation rejects `rate == 0` when enabled, so v1.5.x can only
  near-pause with `capacity > rate > 0` (for example `2/1`), which still leaks.

**Footgun:** `isEnabled=true` with `capacity=0, rate=0` PAUSES (blocks everything), while `isEnabled=false`
with the same numbers REMOVES the limit (unlimited). Identical numbers, opposite behavior; only the flag
differs. The `UpdateRateLimiters` script can set the enabled-`0/0` pause via the explicit
`OUTBOUND_RATE_LIMIT_ENABLED=true` / `INBOUND_RATE_LIMIT_ENABLED=true` override; a `0/0` bucket declared in
the `lanes{}` config resolves to disabled (remove, not pause). See
[operations: rate limits](../operations/rate-limits.md).

## Fast-finality bucket fallback (v2.0)

A v2.0 pool has a separate fast-finality rate limiter, but the fast-finality consume FALLS BACK to the
standard bucket when the fast-finality bucket is disabled. So the "pause standard leaves fast-finality
flowing" bypass bites ONLY when a separate fast-finality bucket is enabled with headroom; on a default
pool (fast-finality disabled) the standard pause already covers fast-finality transfers. A full pause of a
pool whose fast-finality bucket is enabled must throttle both bucket sets.

## Proof

Every claim above is proven by a passing fixture against the real deployed bytecode of each version:

- [`test/reference/RateLimiterVersionBehavior.t.sol`](../../test/reference/RateLimiterVersionBehavior.t.sol)
  backs the validation boundary, the `capacity=1, rate=1` pause difference, the enabled-`0/0` pause and its
  disabled-`0/0` footgun, and the fast-finality fallback.
- [`test/reference/DecimalsMeteringVersionBehavior.t.sol`](../../test/reference/DecimalsMeteringVersionBehavior.t.sol)
  backs the inbound-metering decimals difference across all four versions.

These deltas belong in the pause, rate-limit, and adoption flows as callouts. For the version catalog and
support range, see [pool versions](../pool-versions.md).
