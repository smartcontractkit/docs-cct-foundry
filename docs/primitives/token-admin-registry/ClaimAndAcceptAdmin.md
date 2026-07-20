---
name: ClaimAndAcceptAdmin
script: script/setup/ClaimAndAcceptAdmin.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# ClaimAndAcceptAdmin

Claims AND accepts the CCIP token admin as ONE atomic registration pair - the claim sets the executing account as the registry's pending administrator, so the accept in the same batch succeeds.

**When to use.** Register a token you control in the TokenAdminRegistry in one atomic step. Prefer this over separate ClaimAdmin then AcceptAdminRole when you want a single Safe batch: AcceptAdminRole on its own preflight-requires the pending administrator to already be set, so the two standalone steps cannot be deferred into one batch, whereas this pair executes together.

## Inputs

| Env var | Description |
| --- | --- |
| `CCIP_ADMIN_ADDRESS` | See the script header. |

## Example

```bash
CCIP_ADMIN_ADDRESS=0xYourAdmin forge script script/setup/ClaimAndAcceptAdmin.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
```

## Preconditions

The executing account must be resolvable as the token's admin through one of the three claim paths, auto-detected in precedence: getCCIPAdmin(), then owner(), then AccessControl DEFAULT_ADMIN_ROLE.

## Postconditions

The TokenAdminRegistry administrator for the token is the executing account.

## Known failure modes

Reverts if no claim path resolves the executing account as the token admin, or if the token is already registered to a different administrator.

## Reference

- Script: [`script/setup/ClaimAndAcceptAdmin.s.sol`](../../../script/setup/ClaimAndAcceptAdmin.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
