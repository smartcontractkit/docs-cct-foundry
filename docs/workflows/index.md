---
type: index
---

# Workflows

Composed flows: ordered step-lists that chain the [primitives](../primitives/index.md) into an outcome,
written once and parameterized by governance mode. Each workflow has a human page and a lean, Arazzo-shaped
JSON manifest beside it (`<name>.arazzo.json`) so an agent can execute the flow deterministically instead
of parsing prose.

The manifest carries only the essential wiring: workflow `inputs`, an ordered list of `steps` (each a
`stepId`, the `primitive` it invokes, its `parameters` as references to workflow inputs or prior step
outputs, one `successCriteria`, and the `outputs` a later step consumes), and workflow-level `outputs`.
The docs gate validates that every `primitive` a manifest names exists in the generated
[catalog](../primitives/catalog.json), so a manifest cannot drift from the code.

Mode is a single input, not a fork: under `mode=safe` the write steps emit one Safe batch to sign instead
of broadcasting; the deploy steps sign with the keystore in both modes.

## Composed workflows

- [Greenfield deploy](greenfield-deploy.md) - deploy a new BurnMint token, register it, and wire a lane.
- [Adopt an existing token](adopt-token.md) - bring a deployed token cross-chain.
- [EOA-to-Safe roles handoff](roles-handoff.md) - move the privileged roles to a Safe.
