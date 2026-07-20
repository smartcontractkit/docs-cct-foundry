---
type: concept
---

# Verifiers (CCVs)

CCIP v2 secures a message with verifiers (CCVs). Each required verifier independently attests to the
message, and only once all required verifications are available does the executor run it on the
destination. For a token transfer this is application-based security the token issuer controls: the issuer
configures which verifiers the lane requires, on the pool.

## The required set, per lane and direction

The issuer sets the required CCVs on the pool's Advanced Pool Hooks, per lane and separately for each
direction: `outboundCCVs` for transfers leaving this chain and `inboundCCVs` for transfers arriving. Every
verifier in the applicable set must attest before the executor runs the transfer.

## Additional verifiers above an amount threshold

The issuer can require more verifiers for larger transfers. A single pool-wide amount threshold
(`CCV_THRESHOLD_AMOUNT`) marks the point at or above which an extra set (`thresholdOutboundCCVs` /
`thresholdInboundCCVs`) also applies. Two things to keep straight: the threshold is a transfer amount, not
a count of verifiers, and it is one pool-wide value, not a per-message argument; and the extra verifiers it
adds are required (they must all attest), not an optional tier. Configure the required sets and the
threshold with the [CCV config primitive](../operations/ccv.md).

## Finality and ordering

Fast finality is requested per message, and a lane can require a deeper source finality before a transfer
is eligible to execute. Execution waits on the full required set (plus the threshold set once the amount
crosses `CCV_THRESHOLD_AMOUNT`); the order in which attestations arrive does not change the outcome, only
when the executor becomes eligible to run.

## Why this matters for diagnosis

Because execution is gated on the required set, a message sits at execution state `0` (not yet executed)
until every required verifier has attested. A failure that names a missing verifier means the executor ran
before the set was complete, which is an executor-side anomaly rather than a verifier fault. See
[diagnosis](diagnosis.md).
