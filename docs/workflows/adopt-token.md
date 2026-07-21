---
type: workflow
---

# Adopt an existing token

Bring a token that already exists on chain cross-chain. Machine wiring in
[`adopt-token.arazzo.json`](adopt-token.arazzo.json); the full narrative, including the two starting
scenarios and what adoption validates, is in [enabling an existing token](../enabling-existing-token.md).

## Steps

1. [`AdoptToken`](../primitives/config-plane/AdoptToken.md) - validate the token (and pool) on chain and
   record them in the project store, so every later step resolves them with zero exports.
2. [`ClaimAndAcceptAdmin`](../primitives/token-admin-registry/ClaimAndAcceptAdmin.md) - register the token
   admin. The claim path (`getCCIPAdmin`, then `owner`, then AccessControl `DEFAULT_ADMIN_ROLE`) is
   auto-detected. Skip if the token is already registered.
3. [`SetPool`](../primitives/token-admin-registry/SetPool.md) - point the registry at the pool.
4. [`ApplyChainUpdates`](../primitives/token-admin-registry/ApplyChainUpdates.md) - wire the lane.

Run on both chains, then send. Mode behaves as in the [greenfield workflow](greenfield-deploy.md#mode).
