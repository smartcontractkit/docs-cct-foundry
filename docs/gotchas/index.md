---
type: index
---

# Gotchas

An austere, one-line registry of known facts that bite integrators, each under a stable anchor other docs
link to.

## Registry

<a id="pool-version-pinned"></a>
- **Pool version is pinned to 2.0.0 in the deploy path.** Migration coexistence is not reachable through
  the deploy scripts; the migration guide points at the fixture instead.

<a id="single-valued-active-pointer"></a>
- **The `active.<role>` pointer is single-valued.** On a two-token chain, zero-export resolution returns
  the last-deployed pool for both tokens; storage is collision-free but resolution is not. Thread
  `GROUP=` or an explicit address.

<a id="allowlist-frozen-at-deploy"></a>
- **The allowlist enable-flag is frozen at hooks construction.** Deploy Advanced Pool Hooks with a
  non-empty initial allowlist to keep allowlisting available; an empty initial allowlist turns it off
  permanently. There is no setter to flip it: changing whether allowlisting is on or off means deploying a
  new `AdvancedPoolHooks` and re-pointing the pool at it with `UpdateAdvancedPoolHooks`.

<a id="getexecutionstate-signature-versioned"></a>
- **`getExecutionState` has three version-specific signatures.** v2.0 `getExecutionState(bytes32
  messageId)`; v1.6.x `getExecutionState(uint64 sourceChainSelector, uint64 sequenceNumber)`; v1.5.x
  `EVM2EVMOffRamp.getExecutionState(uint64 sequenceNumber)`. Resolve the OffRamp `typeAndVersion` first; a
  wrong-arity `cast call` decodes garbage.

<a id="enabled-zero-zero-pauses"></a>
- **`isEnabled=true` with `capacity=0, rate=0` PAUSES; `isEnabled=false` with the same numbers REMOVES the
  limit.** Identical numbers, opposite behavior; only the flag differs (v1.6+/v2.0; v1.5.x rejects an
  enabled `rate=0`).

<a id="token-decimals-precision"></a>
- **Cross-chain decimals round down and silently discard dust.** A token can have different decimals per
  chain; a v2 pool rescales on the destination with integer division, so a transfer smaller than
  `10**(srcDec-dstDec)` floors to zero on the destination (burned on source, never minted on dest). The
  pool's declared local decimals must equal the token's decimals at deploy time.

<a id="lane-teardown-edges"></a>
- **Removing a remote pool is not removing a lane, and re-adding a lane reactivates stale config.**
  Removing a remote pool leaves the chain supported with zero pools, so inbound release-or-mint reverts
  with a source-pool error. Chain removal wipes rate-limit config while CCV and fee config persist keyed
  by selector, so re-adding a lane silently reactivates the stale CCV/fee config.

<a id="factory-cannot-deploy-hooks"></a>
- **The factory cannot deploy hooks.** A factory-deployed pool starts with allowlist and CCV off; Advanced
  Pool Hooks must be deployed directly and attached before ownership moves to a Safe.

<a id="two-governance-axes"></a>
- **Pool ownership and the TokenAdminRegistry administrator are two separate authorities.** Pool ownership
  governs config; the registry administrator governs the set-pool cutover, and they can be different
  holders. A timelock owning the pool does not delay-gate a migration cutover unless the registry
  administrator moves under it too; keep the rate-limit admin on the Safe for fast emergency throttles.

_The registry grows as findings graduate from the internal vault under the publication gate._
