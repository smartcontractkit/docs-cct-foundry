---
type: concept
---

# Diagnosis: reading a transfer's status

To monitor a transfer, use one of two RPC-free entry points onto the same CCIP index:

- `ccip-cli show <messageId>` (first `unset CCIP_API_URL`), or
- `GET https://api.ccip.chain.link/v2/messages/<messageId>` (`curl` + `jq`).

Both return the full cross-chain lifecycle, including the off-chain statuses (source finality,
verification, executor pickup) plus the final status and the decoded failure reason, with no RPC and no
API key. That is the whole monitoring answer for an end user. The [send, track, and diagnose
guide](../guides/send-track-diagnose.md) shows both side by side.

## Why the API is enough, and on-chain state is not the monitoring tool

The API returns the full lifecycle. On-chain `getExecutionState` is binary (`0` untouched, then `2`
success or `3` failure) and is only readable after execution, so it confirms an outcome but cannot track
an in-flight message. A `3` is a real failure written after the executor ran, not a pending state. That
is why `getExecutionState` is an advanced forensics tool, not the monitoring tool.

## The v2 execution model (verifiers then executor)

In CCIP v2 there is no DON executing messages. The pipeline is verifiers (CCVs) then executor: each
required verifier attests, and once all required verifications are available the executor runs the message
on the destination. A `3` that carries `RequiredCCVMissing` means the executor ran prematurely (an
executor-side anomaly), not normal operation. Do not treat a `3` as something to wait out; diagnose it.

## The `getExecutionState` version footgun

`getExecutionState` has three version-specific signatures because the OffRamp architecture changed:

- v2.0 `OffRamp`: `getExecutionState(bytes32 messageId)`
- v1.6.x `OffRamp` (one per dest, many sources): `getExecutionState(uint64 sourceChainSelector, uint64 sequenceNumber)`
- v1.5.x `EVM2EVMOffRamp` (one per lane): `getExecutionState(uint64 sequenceNumber)`

A `cast call` with the wrong arity silently fails or decodes garbage, so resolve the OffRamp
`typeAndVersion` first. See the [gotcha](../gotchas/index.md#getexecutionstate-signature-versioned). This
is exactly why `getExecutionState` stays off the end-user monitoring path and lives only in
[troubleshooting](../troubleshooting/index.md) as a forensics escape hatch for the rare leg that failed
then recovered, whose earlier failed attempt the API hides.
