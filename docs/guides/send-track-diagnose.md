---
type: guide
---

# Send, track, and diagnose a transfer

Send a token transfer, then track it to completion and diagnose a failure. Sending and tracking use
`ccip-cli`, which is a testing tool, not a build or deploy dependency: the toolkit deploys, wires, and
configures with Foundry and make alone. See the
[prerequisites](../reference/prerequisites.md#to-send-and-monitor-a-transfer) for installing it.

## Send

```bash
unset CCIP_API_URL   # a value in .env crashes ccip-cli's strict parser
ccip-cli send \
  --source <src-chain> --dest <dest-chain> \
  --router <src-router> --receiver <receiver> \
  --transfer-tokens <token>=<amount> --approve-max
```

Let the CLI own the allowance (`--approve-max`); do not pre-approve manually. The command prints the
`messageId`.

## Track

There is one monitoring story with two equivalent, RPC-free entry points onto the same CCIP index. Pick by
taste; both return the full lifecycle (source finality, verification, executor pickup) plus the final
status and any decoded failure reason.

Via the CLI:

```bash
unset CCIP_API_URL
ccip-cli show <messageId> --json
```

Via the REST API directly (only `curl` + `jq`, which the config sync already needs):

```bash
curl -s https://api.ccip.chain.link/v2/messages/<messageId> | jq
```

A `status` of `SUCCESS` with a `receiptTransactionHash` means the transfer executed on the destination.

## The validation loop: send, check, fix, re-execute

The practical way to validate a lane is a tiny **token-only transfer to your own EOA**, then
`ccip-cli show`:

- `ccip-cli show <messageId>` reports the message **executed successfully** (`state: 2`): the config is
  right.
- It reports **failed on the destination** (`state: 3`): read the decoded reason, fix the config, and
  re-execute the SAME message with `ccip-cli manualExec`. You do not re-send.

When a token-only transfer fails, the failure is in the **pool**: the destination pool is not authorized
to mint or release, the remote pool is mis-wired (`InvalidSourcePoolAddress`), or the inbound rate limiter
rejects the amount.

### Read the failure reason

```bash
ccip-cli show <messageId> --rpcs <dest-rpc> --json --no-interactive
```

For a token-only transfer whose destination pool cannot mint, `show` returns the pool failure and
`ccip-cli parse` decodes it down to the reason string:

```bash
ccip-cli parse <returnData-hex>
# TokenHandlingError(address target, bytes err)
#   target = <destination token>
#   err    = Error(string): "AccessControl: account <pool> is missing role <MINTER_ROLE>"
```

That names the exact fix: grant the destination pool the token's mint role. The CLI decodes known CCIP
errors and, here, the token's standard `Error(string)` too. Common CCIP-level reasons are in
[troubleshooting](../troubleshooting/index.md). A `state: 3` from a pool authorization failure,
`InvalidSourcePoolAddress`, `RequiredCCVMissing`, or a rate-limit revert is a CONFIGURATION problem to fix
(grant the role, rewire the pool, raise the limit).

### Re-execute after the fix

The first execution is automatic: once the source reaches finality and the required verifiers attest, the
message runs on the destination. If it failed and you have fixed the config, re-execute the SAME message
yourself with `ccip-cli manualExec`. You do not re-send: a `state: 3` (FAILURE) message is re-executable
on the destination OffRamp, so re-running it delivers the tokens the original send already paid for.

```bash
ccip-cli manualExec <messageId> --rpcs <src-rpc> --rpcs <dest-rpc> --wallet <key> --no-interactive
```

`manualExec` re-runs the SAME message on the destination OffRamp; it does not create a new message or move
tokens twice. Confirm recovery with `ccip-cli show` (or `getExecutionState`, which reads `2`). `manualExec`
is the subcommand (`manual-exec` is an alias); pass a `<srcTx>` in place of the messageId if you do not
have it.

Do NOT use `manualExec --only-estimate` to classify a token-only pool failure. The estimate does not
exercise the pool's mint or release, so it returns a tiny number that looks fine while the real release
reverts. Classify from the decoded reason instead: a `TokenHandlingError`, `InvalidSourcePoolAddress`, or
rate-limit revert is a config fault to fix, not a gas fault.

On-chain `getExecutionState` is NOT the first monitoring tool (RPC-bound, binary, and its signature
differs per OffRamp version); reach for it only to confirm recovery (`3` then `2`) or for the rare leg that
failed then recovered, whose earlier failure the API hides. The concept behind the status values and the verifiers-then-executor model
is in [diagnosis](../concepts/diagnosis.md).

## Triangulate (when a result must be trusted)

For a result you must trust, cross-check the message across the REST API, `ccip-cli show` with the API,
`ccip-cli show` without the API (on-chain path), and a direct on-chain read, and require agreement. Any
disagreement is a finding, not a rounding error.
