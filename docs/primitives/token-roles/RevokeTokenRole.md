---
name: RevokeTokenRole
script: script/setup/token-roles/RevokeTokenRole.s.sol
group: token-roles
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# RevokeTokenRole

Revokes a token role (minter / burner / burnMintAdmin) from a holder, template-dispatched exactly like `GrantTokenRole`: `revokeRole` on AccessControl templates, `revokeMintRole`/`revokeBurnRole` on the Ownable `factory` template.

## Inputs

| Env var | Description |
| --- | --- |
| `HOLDER` | See the script header. |
| `ROLE` | See the script header. |

## Reference

- Script: [`script/setup/token-roles/RevokeTokenRole.s.sol`](../../../script/setup/token-roles/RevokeTokenRole.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
