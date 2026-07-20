---
type: guide
---

# Health-check a deployment before mainnet

Run this static check before a mainnet launch, then walk the full
[production checklist](../production-checklist.md). This guide is the fast pre-flight; the checklist is
the complete gate.

## The checks

1. **Config and wiring.** `make doctor CHAIN=<name>` on every chain: it verifies on-chain code at the
   recorded token and pool addresses, the `TokenAdminRegistry` reconciliation, and the lane wiring.
2. **Roles.** `make roles-check CHAIN=<name>` (or `make roles-check-all`): a read-only reconcile of the
   declared `roles{}` authority against the live chain. Expect exit 0. See [roles](../roles.md).
3. **Verification.** Confirm each deployed contract is source-verified on its explorer (`make verify`
   backfill if needed).
4. **Smoke transfer.** Send a small transfer in BOTH directions and confirm each reaches `SUCCESS`, using
   the [send, track, and diagnose guide](send-track-diagnose.md). A green static check plus a real
   round-trip is what proves the lane, not either alone.

## What a clean run looks like

`make doctor` green up to the expected project-placeholder warnings, `make roles-check` at exit 0, every
contract verified on its explorer, and a `SUCCESS` smoke transfer each way. Anything less is a launch
blocker, not a warning to note and move past.
