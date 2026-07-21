---
type: concept
---

# Fees

A v2 token transfer carries two independent costs, charged in different ways and observable in different
places. Only v2 pools on v2 lanes charge a pool fee; the mechanics below apply there.

## The CCIP fee, paid in the fee token

Paid in LINK or the native token at send time. It is the base network cost (verifiers, executor,
destination gas) plus, on a v2 pool, a **flat per-lane pool fee** the token issuer sets: `finalityFeeUSDCents`,
or `fastFinalityFeeUSDCents` for a fast-finality message, denominated in USD cents. The flat pool fee is
added to the CCIP fee, routed to the pool, and **is included in a read-only `getFee` quote**.

## The pool bps fee, deducted from the transferred tokens

Separately, a v2 pool can charge a **basis-points fee on the amount**: `finalityTransferFeeBps`, or
`fastFinalityTransferFeeBps`, in basis points (`amount * bps / 10_000`). This fee is **not** part of the CCIP
fee. The pool deducts it from the transfer itself: it locks or burns `amount - fee`, so the receiver gets the
post-fee amount, and the skimmed remainder accrues on the pool (swept later with `withdrawFeeTokens`).
Configure both the flat and bps parameters with the [fee config primitive](../operations/fees.md).

## A quote knows the flat fee, not the bps fee

A `getFee` quote returns the CCIP fee, which includes the flat pool fee, but **never the bps fee**. The bps
fee only manifests as the reduced delivered amount at execution. So do not treat a quote as the full cost
when a bps fee is configured: you see the bps deduction only in the received amount, or after the send in
the CCIP REST API. This is the one asymmetry to remember: flat pool fee visible in the quote, bps pool fee
not.

## Only v2 pools on v2 lanes

Both pool fees live on the v2 `TokenPool` itself, keyed per destination chain selector, and are charged only
when the pool implements `IPoolV2` and the lane runs the v2 OnRamp. On a v1.5 lane, against a v1 pool, or
when the pool's fee config is disabled, the pool charges no per-lane transfer fee; the FeeQuoter's own
token-transfer fee applies instead. So a pool fee you configure only takes effect on a v2-pool, v2-lane path.

## Per-finality pricing

Fast finality (FTF) is a per-message finality selector, and the issuer prices it independently: a v2 pool
holds a separate flat fee, a separate bps, and a separate rate limiter for fast-finality transfers, so the
same lane can charge a different amount for a faster transfer. The finality extra-args format is
version-specific, and v2 finality fields revert on a pre-v2 lane. See [pool versions](../pool-versions.md)
for the per-version behavior.
