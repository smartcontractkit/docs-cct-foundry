---
name: GrantTokenRole
script: script/setup/token-roles/GrantTokenRole.s.sol
group: token-roles
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: false
---

# GrantTokenRole

Grants a token role (minter / burner / burnMintAdmin) to a holder, template-dispatched: AccessControl templates (`crosschain`, `burnmint`) get `grantRole` with the token's resolved role id; the Ownable `factory` template gets `grantMintRole`/`grantBurnRole`.

## Inputs

| Env var | Description |
| --- | --- |
| `HOLDER` | See the script header. |
| `ROLE` | See the script header. |

## Reference

- Script: [`script/setup/token-roles/GrantTokenRole.s.sol`](../../../script/setup/token-roles/GrantTokenRole.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
