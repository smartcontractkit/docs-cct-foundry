---
name: DeployToken
script: script/deploy/DeployToken.s.sol
group: deploy
type: reference
modes: [eoa]
read_only: false
writes_onchain: true
destructive: false
---

# DeployToken

Deploys a cross-chain ERC20 token (CrossChainToken) and records it in the address registry.

## Inputs

| Env var | Description |
| --- | --- |
| `CCIP_ADMIN_ADDRESS` | See the script header. |
| `ROLES_RECIPIENT` | See the script header. |
| `TOKEN_DECIMALS` | See the script header. |
| `TOKEN_MAX_SUPPLY` | See the script header. |
| `TOKEN_NAME` | See the script header. |
| `TOKEN_PRE_MINT` | See the script header. |
| `TOKEN_PRE_MINT_RECIPIENT` | See the script header. |
| `TOKEN_SYMBOL` | See the script header. |

## Reference

- Script: [`script/deploy/DeployToken.s.sol`](../../../script/deploy/DeployToken.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
