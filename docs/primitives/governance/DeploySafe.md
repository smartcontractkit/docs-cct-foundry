---
name: DeploySafe
script: script/governance/DeploySafe.s.sol
group: governance
type: reference
modes: [eoa]
read_only: false
writes_onchain: true
destructive: false
---

# DeploySafe

Deploys a Safe from the canonical Safe v1.4.1 stack: `SafeProxyFactory.createProxyWithNonce(SafeL2, setup(...), saltNonce)`.

## Inputs

| Env var | Description |
| --- | --- |
| `SAFE_OWNERS` | See the script header. |
| `SAFE_SALT_NONCE` | See the script header. |
| `SAFE_THRESHOLD` | See the script header. |

## Reference

- Script: [`script/governance/DeploySafe.s.sol`](../../../script/governance/DeploySafe.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: true | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
