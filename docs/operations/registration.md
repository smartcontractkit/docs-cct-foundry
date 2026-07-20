---
type: reference
---

# Register the token with CCIP

Claim the CCIP admin role for a token, accept it, and point the token at its pool. Scripts under
`script/setup/`. Primitive pages:
[`ClaimAdmin`](../primitives/token-admin-registry/ClaimAdmin.md),
[`AcceptAdminRole`](../primitives/token-admin-registry/AcceptAdminRole.md),
[`SetPool`](../primitives/token-admin-registry/SetPool.md),
[`ClaimAndAcceptAdmin`](../primitives/token-admin-registry/ClaimAndAcceptAdmin.md). The atomic
claim-and-accept pattern is explained in [Composition](../concepts/composition.md).

## Claim admin

Run on each chain. The claim auto-detects how the token exposes its admin and self-registers through
the matching `RegistryModuleOwnerCustom` method, probed in a fixed precedence:

1. `getCCIPAdmin()` (the CrossChainToken and factory templates)
2. `owner()` (an `Ownable` token)
3. OpenZeppelin AccessControl `DEFAULT_ADMIN_ROLE` (an adopted AccessControl-only token)

The script logs the path it took (for example `Admin Method: AccessControl DEFAULT_ADMIN_ROLE`). For an
AccessControl token, the caller must hold `DEFAULT_ADMIN_ROLE` on the token.

```bash
# On Ethereum Sepolia
forge script \
  script/setup/ClaimAdmin.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/ClaimAdmin.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Set `CCIP_ADMIN_ADDRESS=0x...` to specify the token's current admin address (defaults to the EOA
broadcasting the transaction).

## Accept admin role

Run on each chain to complete the two-step registration.

```bash
# On Ethereum Sepolia
forge script \
  script/setup/AcceptAdminRole.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/AcceptAdminRole.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

`AcceptAdminRole` requires the pending administrator to already be set, so `ClaimAdmin` then
`AcceptAdminRole` cannot be deferred into one Safe batch. To land both in a single atomic batch, use
`ClaimAndAcceptAdmin`, which concatenates register and accept; see
[Composition](../concepts/composition.md).

## Set pool

Point the token at its pool in the TokenAdminRegistry. Run on each chain, after the lane is wired (see
[Lanes and remote pools](lanes-and-remotes.md)).

```bash
# On Ethereum Sepolia
forge script \
  script/setup/SetPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/SetPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

To move the TokenAdminRegistry administrator to a new address, see [Ownership and admin
handoff](ownership.md).
