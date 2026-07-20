---
type: index
---

# Troubleshooting

A symptom-to-diagnosis-to-fix catalog. Each entry quotes the error (the match key), gives the diagnosis
command, the fix, and a self-verify. Start from the error you see.

## `ccip-cli` exits immediately with a yargs / strict-parser error

- **Diagnosis.** A `CCIP_API_URL` value is set in the environment (often from a sourced `.env`). It maps
  to a non-existent CLI option and crashes the strict parser.
- **Fix.** `unset CCIP_API_URL` before running any `ccip-cli` command.
- **Verify.** `ccip-cli show <messageId>` returns the message lifecycle instead of crashing.

## A send never executes on the destination (execution state stays `0`)

- **Diagnosis.** `0` (UNTOUCHED) means the message has not been executed yet, not that it failed. In CCIP
  v2 the executor does not run until the source reaches finality and every required verifier has attested.
- **Fix.** Wait for finality and verification; track progress with `ccip-cli show <messageId>` or
  `GET /v2/messages/<id>`, which surface the off-chain finality and verification statuses.
- **Verify.** The status advances to `SUCCESS` with a `receiptTransactionHash`. See
  [diagnosis](../concepts/diagnosis.md).

## Execution state `3` (FAILURE) on a v2 lane

- **Diagnosis.** `3` is a real failure written after the executor ran, never a pending state. Read the
  decoded reason with `ccip-cli show <messageId> --rpcs <dest> --json` (or `ccip-cli parse <returnData>`);
  `cast run <failedDestTx>` gives the ground-truth frame. Common causes: the destination pool cannot mint
  or release, a mis-wired remote pool (`InvalidSourcePoolAddress`), or a rate-limit rejection. A `3`
  carrying `RequiredCCVMissing` means the executor ran before all required verifications were available,
  an executor-side anomaly to report, not a state to wait out.
- **Fix.** Address the specific revert (grant the pool its mint role, rewire the remote pool, raise the
  rate limit), then **re-execute the SAME message with `ccip-cli manualExec`, do not re-send**: a
  `state: 3` message is re-executable in v2.
  `ccip-cli manualExec <messageId> --rpcs <src> --rpcs <dest> --wallet <key>`.
- **Verify.** `getExecutionState` reads `2` (SUCCESS) after the retry. Resolve the OffRamp version first (the
  signature differs by version, see the [gotcha](../gotchas/index.md#getexecutionstate-signature-versioned)).

## A token-only transfer fails at the destination with `TokenHandlingError`

- **Diagnosis.** `ccip-cli parse <returnData>` decodes it to `TokenHandlingError(address target, bytes err)`
  where `target` is the destination token and `err` is `Error(string): "AccessControl: account <pool> is
  missing role <MINTER_ROLE>"`. The destination pool was never granted the token's mint role (the classic
  "forgot to make the pool a minter"). The failure is always in the pool.
- **Fix.** Grant the destination pool the token's mint role with the template-aware script (it resolves
  the correct role id for a `crosschain` / `burnmint` token and calls `grantMintRole` on a `factory`
  token):

  ```bash
  ROLE=minter HOLDER=<destPool> forge script script/setup/token-roles/GrantTokenRole.s.sol \
    --rpc-url <dest-rpc> --account <keystore> --broadcast
  ```

  The script refuses a BYO token, whose internal roles it cannot manage; grant that with the token's own
  admin call. Then re-execute the SAME message with `ccip-cli manualExec` as above. Do not use
  `manualExec --only-estimate` to classify this: the estimate does not exercise the mint, so it looks
  fine while the real mint reverts.
- **Verify.** `ccip-cli show <messageId>` reads `SUCCESS` and the EOA balance rose by the transferred amount.

## A `cast` call to `getExecutionState` returns garbage or reverts

- **Diagnosis.** The signature is version-specific across three forms; a wrong-arity call decodes garbage.
- **Fix.** Read the OffRamp `typeAndVersion` first, then use the matching signature (v2.0 `bytes32
  messageId`; v1.6.x `(uint64 sourceChainSelector, uint64 sequenceNumber)`; v1.5.x `(uint64
  sequenceNumber)`).
- **Verify.** The call returns a small integer in `0..3`. See the
  [gotcha](../gotchas/index.md#getexecutionstate-signature-versioned).

## A deploy refuses with an "already deployed" message naming an existing address

- **Diagnosis.** The redeploy guard: the artifact is already recorded in the project store.
- **Fix.** Reuse the recorded address, or set `FORCE_REDEPLOY=true` to override. After a forced pool
  redeploy, rewire the `TokenAdminRegistry` with `SetPool` (the registry still points at the old pool).
- **Verify.** `make doctor CHAIN=<name>` shows the registry pointing at the intended pool.

## Inbound transfer reverts after removing a remote pool

- **Diagnosis.** Removing a remote pool leaves the chain supported with zero pools, so inbound
  release-or-mint reverts with a source-pool error. Removing a pool is not removing a lane.
- **Fix.** Add a valid remote pool back, or remove the chain entirely if the lane is being torn down.
  Chain removal wipes rate-limit config while CCV and fee config persist keyed by selector, so
  re-adding a lane silently reactivates stale config.
- **Verify.** `make doctor` reports the lane with a remote pool present.

## Advanced forensics: a leg that failed then recovered

The REST API and `ccip-cli show` report only the final `SUCCESS` and hide an earlier failed attempt. To
recover a transient revert reason, enumerate every `ExecutionStateChanged` event for the messageId on the
dest OffRamp (a state-3-then-state-2 sequence is reverted-then-recovered), then `cast run <failedDestTx>`
for the parsed revert. This is the one place on-chain `getExecutionState` forensics is the right tool.
