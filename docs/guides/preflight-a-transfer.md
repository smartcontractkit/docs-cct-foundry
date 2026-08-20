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
   make doctor CHAIN=<chain>        # on-chain code at every recorded artifact, TAR reconcile, lane wiring
   make roles-check CHAIN=<chain>   # the privileged roles match the declared authority (exit 0)
   ```

   `doctor` confirms the pools are deployed, registered, and wired for the lane; `roles-check` confirms the
   authority is where you expect. This is the static half: it proves the configuration without moving tokens.

2. **Simulate the transfer with `make preflight` (no send).** This runs `ccip-cli send --only-estimate`,
   which simulates the source pool's `lockOrBurn` and then the destination pool's `releaseOrMint`, fed the
   exact `destPoolData` the source leg produced. Both legs are reachable because they gate only on
   `msg.sender` being a registered ramp, which an `eth_call` satisfies with a spoofed `from`; the full
   `ccipSend` and destination `execute()` cannot be simulated pre-send, because they are proof-gated. It
   prints GO, or NO-GO with the decoded reason, so a misconfigured lane fails here instead of stranding a
   real message.

   ```bash
   make preflight \
     SOURCE_CHAIN=<src-chain> DEST_CHAIN=<dst-chain> \
     AMOUNT=<wei> RECEIVER=<your-EOA>
   ```

   You pass two chain names (the `config/chains/` selectorNames) plus the amount in wei and the receiver,
   exactly like the other targets: it resolves each chain's RPC and the source router from the chain
   configs, and the token from the project store (`TOKEN=` overrides). `AMOUNT` is in wei here and the CLI
   takes human units, so the wrapper converts using the token's `decimals()`. The escape hatch is
   `bash script/config/preflight-transfer.sh <src> <dst> <amountWei> <receiver>`, and under that the raw
   `ccip-cli send --only-estimate --estimate-gas-limit 0`.

   It covers, on the source: the burn or lock authority, the allowlist, and the outbound rate limit. On the
   destination: the source-pool wiring (`InvalidSourcePoolAddress`), the inbound rate limit
   (`TokenMaxCapacityExceeded`), the mint or release authority, the RMN curse, and liquidity. It also checks
   the OffRamp lane gates and, on v2 lanes, the CCV and finality resolve. Every pool version from v1.5.0
   through v2.0 works, dispatched by each pool's own ERC165 answer the same way the ramps do, and
   destinations that are not EVM are covered too. Nothing is sent: exit 0 is GO, exit 1 is NO-GO.

   **The sender matters.** The source pool gates its allowlist on who is sending, so the verdict is
   sender-specific. Set `ORIGINAL_SENDER=<addr>` or `WALLET=<spec>` (`foundry:<name>`, `ledger[:index]`, …)
   when the sender is not the default the CLI resolves; otherwise a clean GO can still be followed by a
   live `SenderNotAllowed`.

   **Two things it does not check**, because the simulation overrides balances to reach the pool at all:
   your own token balance, and the Router allowance. Check those separately. One further gap: on the source
   leg a plain `Error(string)` or `Panic(uint256)` revert is treated as an artifact of that override and
   does not block, so a pool using string-revert access control for burn authority is not covered. Modern
   `chainlink-ccip` pools use custom errors and are.

   **The token must expose `symbol()`, `decimals()` and `name()`.** `ccip-cli` reads all three to resolve
   a token amount and does not tolerate a missing one, so a token that omits any of them cannot be
   preflighted this way - it fails inside the CLI rather than reporting a verdict. All three are optional
   in ERC20, so such a token may still be perfectly good to deploy and transfer; only this check is
   unavailable. Pending guards in `ccip-cli`/`ccip-sdk`.

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
