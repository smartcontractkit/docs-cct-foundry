---
type: guide
---

# Preflight a transfer before sending

Before you rely on real cross-chain transfers, prove the lane end to end without stranding a message. The
preflight is three runnable steps, in order: audit the config, simulate the transfer with `make preflight`
(a GO/NO-GO with no send), then confirm with a tiny real transfer in both directions. This is the send-time
counterpart to the static [health check](health-check.md).

## Recommended preflight

1. **Audit the config with the scripts.** On BOTH chains:

   ```bash
   make doctor CHAIN=<chain>        # on-chain code at the recorded token and pool, TAR reconcile, lane wiring
   make roles-check CHAIN=<chain>   # the privileged roles match the declared authority (exit 0)
   ```

   `doctor` confirms the pools are deployed, registered, and wired for the lane; `roles-check` confirms the
   authority is where you expect. This is the static half: it proves the configuration without moving tokens.

2. **Simulate the transfer with `make preflight` (no send).** This forks both chains and simulates the
   source pool's `lockOrBurn`, then the destination pool's `releaseOrMint` fed the exact data the source leg
   produced, pranking the OnRamp and OffRamp the way production does. It prints GO with the amount the
   destination would receive, or NO-GO with the decoded reason, so a misconfigured lane fails here instead of
   stranding a real message.

   ```bash
   make preflight \
     SOURCE_CHAIN=<src-chain> DEST_CHAIN=<dst-chain> \
     AMOUNT=<wei> RECEIVER=<your-EOA>
   ```

   You pass two chain names (the `config/chains/` selectorNames) plus the amount and receiver, exactly like
   the other targets: it resolves each chain's RPC, router, and selector from its chain config and the pools
   from the project store. Override a not-yet-stored pool with `SOURCE_POOL=` / `DEST_POOL=`. The raw
   `forge script` under it (the escape hatch) is
   `SOURCE_CHAIN=<src> DEST_CHAIN=<dst> SOURCE_RPC_URL=<src-rpc> DEST_RPC_URL=<dst-rpc> AMOUNT=<wei> RECEIVER=<you> forge script script/diagnostics/PreflightTransfer.s.sol`.

   It proves the whole pool path in one command: on the source, the burn or lock authority and outbound rate
   limit; on the destination, the source-pool wiring (`InvalidSourcePoolAddress`), the inbound rate limit
   (`TokenMaxCapacityExceeded`), the mint or release authority (the classic pool-not-a-minter), the RMN
   curse, and liquidity. It works for every pool version (v1.5.0 through v2.0), dispatching each pool by its
   own ERC165 answer the same way the ramps do, and it is read-only: a fork simulation, never a broadcast. A
   NO-GO names the exact fix (plus the pool and token it ran against; re-run with `-vvvv` for the exact
   reverting frame), so make the fix and re-run until GO. Because the pools come from the project store,
   which tracks the active pool, you preflight what is wired, not a decommissioned one.

3. **Confirm with a tiny token-only transfer in BOTH directions.** Once preflight is GO, send a small amount
   to your own EOA, A to B and B to A, and confirm each reaches `SUCCESS`:

   ```bash
   unset CCIP_API_URL
   ccip-cli send --source <A> --dest <B> --router <A-router> --receiver <your-EOA> --transfer-tokens <token>=<tiny> --approve-max
   ccip-cli show <messageId>        # expect status SUCCESS
   # then the reverse direction, B to A
   ```

   Do both steps. Preflight predicts the pool legs before you spend anything; the tiny transfer confirms the
   lane actually carries value end to end (finality, verification, execution), which the fork cannot. Confirm
   BOTH directions because each has its own remote pool, rate limits, and pool wiring, so a one-way test
   leaves the reverse leg unproven. If a direction fails at the destination, the cause is in the pool:
   diagnose it, fix the config, and re-execute the same message with `ccip-cli manualExec`. See
   [send, track, and diagnose](send-track-diagnose.md).

## What a stuck or failed transfer means

If a transfer does not execute on the destination, the cause is one of these, all of which `make preflight`
surfaces before you send:

- **Destination liquidity.** A LockRelease destination pool (or its lockbox) must hold enough liquidity to
  release the amount. A BurnMint destination mints, so it has no liquidity constraint, but its pool must
  hold the token's mint role and not be rate-limit-blocked.
- **Rate limits.** The destination inbound rate limiter must have capacity for the amount; a near-paused
  limiter rejects the release or mint.
- **Pool wiring.** The destination pool must have the source pool registered as its remote for the lane, or
  the release reverts `InvalidSourcePoolAddress`.
- **Source side.** The source pool must hold the burn or lock authority and have outbound rate-limit
  capacity, and the sending wallet must hold the fee token.

Finality is the one thing preflight does not cover: the message is not executed until the source transaction
reaches the required finality and every required verifier has attested, so a too-recent send sits at a `0`
execution state, which is not a failure. See [diagnosis](../concepts/diagnosis.md) for how the status values
map to what actually happened.
