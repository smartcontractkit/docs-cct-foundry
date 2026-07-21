---
type: workflow
---

# EOA-to-Safe roles handoff

Move a deployment's privileged roles from the deployer EOA to a Safe. The
[`roles-handoff.arazzo.json`](roles-handoff.arazzo.json) manifest is a machine skeleton of the phases; the
**authoritative** ceremony (the grant-new-before-revoke-old ordering, the pre-revoke gate, the token-admin
grant per template, and the residual-holder sweep) is in [roles](../roles.md#the-eoa--safe-handoff-ceremony).
Do not reorder grants and revokes from the skeleton alone.

## Phases

1. [`DeploySafe`](../primitives/governance/DeploySafe.md) - deploy the recipient Safe (or reuse one).
2. Grant / initiate (step A, from the EOA): move each authority toward the Safe -
   [`TransferTokenAdminRole`](../primitives/token-admin-registry/TransferTokenAdminRole.md),
   [`TransferOwnership`](../primitives/ownership/TransferOwnership.md) on the pool, and
   [`SetDynamicConfig`](../primitives/dynamic-config/SetDynamicConfig.md) for the rate-limit and fee admins.
   For the token's top-level admin use
   [`TransferTokenAdmin`](../primitives/token-roles/TransferTokenAdmin.md) (template-aware).
3. Gate: `make roles-check` must exit 0 for the pending state before any revoke.
4. Accept (step B, from the Safe, `MODE=safe`):
   [`AcceptAdminRole`](../primitives/token-admin-registry/AcceptAdminRole.md) and
   [`AcceptOwnership`](../primitives/ownership/AcceptOwnership.md), composed into one batch.
5. Verify: [`VerifyRoles`](../primitives/governance/VerifyRoles.md) / `make roles-check` reports clean.

See [governance modes](../governance-modes.md) for the Safe batching and signing ceremony.
