---
type: concept
---

# Composition: combining operations into one batch

You can combine operations into one atomic batch, not only use the pre-baked wrappers.
The design principle "deterministic building blocks, composed" states it; this page shows how, so you can
compose your own batches rather than reaching for a bespoke script.

## The mechanism

Each **write** primitive is an **action builder** that returns a typed `CctActions.Call[]` (a target,
value, and calldata per call) instead of broadcasting immediately (read-only primitives just read and
print, they build no calls). Composition is three steps:

1. Build the calls from each primitive.
2. `concat` several `Call[]` arrays into one.
3. `executeCalls` runs the merged array.

The same array is mode-agnostic. Under EOA execution, `executeCalls` broadcasts the calls in
sequence. Under `MODE=safe`, it emits one merged MultiSend meta-transaction that the Safe owners sign
once. You write the composition once; the mode decides how it lands.

## Worked example: `ClaimAndAcceptAdmin`

`ClaimAndAcceptAdmin` is exactly a composition:

```solidity
executeCalls(concat(
    registerAdmin(...),      // register the token in the TokenAdminRegistry (the probed claim path)
    acceptAdminRole(...)     // accept the pending administrator role
));
```

Two primitives, concatenated into one `Call[]`, run together. Under a Safe that is a single meta-tx: the
claim and its accept land atomically, signed once.

## Why compose rather than run two scripts

Composition does more than save a step: it makes atomic batches possible that a sequence of standalone operations cannot
achieve under deferred or Safe execution.

`AcceptAdminRole` on its own preflight-requires the pending administrator to already be set on chain.
So running `ClaimAdmin` and then `AcceptAdminRole` as two separate Safe batches does not work: at the time
you build the second batch, the pending administrator is not set yet, and its preflight fails. You cannot
defer the two into one Safe batch as standalone steps.

Concatenating register + accept can, because the pair executes together in the same transaction: the
register call sets the pending administrator, and the accept call runs immediately after, in the same
atomic batch, so its precondition is satisfied at execution time.

This is the general lesson: when a later operation's precondition is established by an earlier one,
composition into a single atomic batch is what makes the sequence expressible under Safe or any deferred
execution.

## See also

- The [Safe governance guide](../governance-modes.md) uses this as the worked example for batching.
- The [primitives catalog](../primitives/index.md) marks each primitive read-only, write, or destructive,
  and lists its execution modes.
