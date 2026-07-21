---
type: index
---

# Documentation

The map into this repository's documentation. Humans start here or at the
[README](../README.md); agents start at [AGENTS.md](../AGENTS.md). Every fact is authored once and
linked, never mirrored.

The docs follow four forms: **get-started** (learn by doing), **guides** (accomplish an outcome),
**reference** (look a fact up), and **concepts** (understand why). A **learnings layer**
(troubleshooting, gotchas, decisions) captures hard-won operational knowledge.

## Get started

- [Quick start](../README.md#quick-start) - deploy a token and a pool to a testnet and send a transfer.
- [Production checklist](production-checklist.md) - the ordered list to walk before a mainnet launch.
- [Prerequisites](reference/prerequisites.md) - layered by whether you deploy, send, or run on a testnet.

## Primitives catalog (the building blocks)

- [`docs/primitives/`](primitives/) - one page per user-facing script and make target: description,
  modes, safety flags, and inputs. Generated from the scripts so it cannot drift.
- [`docs/primitives/catalog.json`](primitives/catalog.json) - the machine-readable index for agents.

## Guides (outcomes)

How-to guides for a specific outcome live under [`docs/guides/`](guides/index.md). Highlights:

- [Send, track, and diagnose a transfer](guides/send-track-diagnose.md).
- [Enabling an existing token (adoption)](enabling-existing-token.md).

## Workflows (composed, agent-executable)

Multi-step flows with a machine-readable manifest each, under [`docs/workflows/`](workflows/index.md):
[greenfield deploy](workflows/greenfield-deploy.md), [adopt a token](workflows/adopt-token.md), and the
[EOA-to-Safe roles handoff](workflows/roles-handoff.md).

## Reference (look it up)

- [Pool versions](pool-versions.md) - how the repo decides what a pool is, and the per-version support matrix.
- [Pool-version behavior deltas](reference/pool-behavior-matrix.md) - rate-limit validation, pause, decimals metering, and fast-finality differences, each fixture-backed.
- [Config and project-store schema](config-schema.md) - every field of `config/chains` and `project/`.
- [Config architecture](config-architecture.md) - the layering, sync data-flow, and writers.
- [Deployed addresses](deployed-addresses.md) - the project store, resolution ladder, and redeploy guard.

## Concepts (understand why)

- [Roles](roles.md) - the authority durable store, the two governance axes, and reconciliation.
- [Governance modes](governance-modes.md) - EOA and Safe execution, batching, and the signing ceremony.
- [Composition](concepts/composition.md) - combining primitives into one atomic batch (the `ClaimAndAcceptAdmin` example).
- [The store model](concepts/store-model.md) - config vs project vs history, token groups, and the redeploy guard.
- [Diagnosis](concepts/diagnosis.md) - reading a transfer's status and the `getExecutionState` version footgun.
- [Verifiers (CCVs)](concepts/verifiers-ccv.md) - required vs optional verifiers, the additional-CCV threshold, and finality.
- [Fees](concepts/fees.md) - fee composition and the bps-fee observability trap.

## Learnings layer

- Decisions (ADRs): [signing with a keystore](decisions/0001-keystore-signing.md).
- Troubleshooting and gotchas: see [`docs/troubleshooting/`](troubleshooting/) and
  [`docs/gotchas/`](gotchas/).
