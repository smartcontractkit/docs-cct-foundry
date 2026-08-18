---
type: reference
---

# Reading a write script's outcome line

Every write primitive names what the run actually did in one of the three lines below. Multi-step scripts
print the line per step and again in the closing banner, so it can appear several times in one run -
always the same line, since one decision selects it.

The line is printed from the script body, which `forge script` runs as a SIMULATION: forge dispatches
the recorded transactions only after the body returns. No line can therefore report a landed
transaction, and none of the three claims to.

| Line                                                       | What happened                                                                              | What to do next                                                                      |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `⏳ SENDING (unconfirmed): <operation>`                     | The calls were handed to forge to send. `--broadcast` (or `--resume`) is set.               | Check forge's exit code, then read the state back.                                    |
| `🔍 NOT SENT (simulation only, add --broadcast): <operation>` | A dry run. The calls were built and discarded; nothing was sent.                            | Re-run with `--broadcast` when the simulation looks right.                            |
| `📝 NOT SENT (Safe batch to sign): <operation>`             | `MODE=safe` without `SAFE_EXEC=direct`: a batch was written under `batches/` for the owners. | Review and sign the batch. See [governance modes](../governance-modes.md).            |

`MODE=safe` writes the batch file under `batches/` before it reads `SAFE_EXEC`, so a batch is always
written. `SAFE_EXEC=direct` then also submits, and reports through the first two rows: `SENDING` with
`--broadcast`, the dry-run line without. Only the batch row is independent of `--broadcast`.

`<operation>` is a verb phrase naming the operation, for example `set the pool on the
TokenAdminRegistry`.

The outcome line is not a confirmation. What confirms the on-chain state is reading it back:
`make doctor CHAIN=<name>`, `make roles-check CHAIN=<name>`, or the matching `Get*` script. A
`SENDING` line with a nonzero forge exit code means the operation did not land, and the project store
may still hold the address the simulation recorded (see
[troubleshooting](../troubleshooting/index.md#a-deploy-refuses-naming-an-address-that-has-no-code-on-the-chain)).

Read-only primitives (`doctor`, `roles-check`, the getters) do not print an outcome line; their
vocabulary is `[PASS]`/`[FAIL]`/`[WARN]`/`[SKIP]` plus a verdict, documented in
[adding a chain and the config tooling](../operations/chains.md).
