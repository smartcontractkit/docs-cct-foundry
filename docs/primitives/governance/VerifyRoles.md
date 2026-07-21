---
name: VerifyRoles
script: script/governance/VerifyRoles.s.sol
group: governance
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# VerifyRoles

**The privileged-role audit reader (read-only)** - prints the CURRENT holder of every authority slot for a token / pool / lockbox / hooks set.

## Inputs

| Env var | Description |
| --- | --- |
| `TAR` | See the script header. |
| `TOKEN` | See the script header. |
| `TOKEN_POOL` | See the script header. |

## Reference

- Script: [`script/governance/VerifyRoles.s.sol`](../../../script/governance/VerifyRoles.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
