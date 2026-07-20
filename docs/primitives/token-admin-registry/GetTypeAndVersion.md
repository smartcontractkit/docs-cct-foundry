---
name: GetTypeAndVersion
script: script/setup/GetTypeAndVersion.s.sol
group: token-admin-registry
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# GetTypeAndVersion

Reads and displays the typeAndVersion string from any contract implementing ITypeAndVersion.

## Inputs

| Env var | Description |
| --- | --- |
| `ADDRESS` | See the script header. |

## Reference

- Script: [`script/setup/GetTypeAndVersion.s.sol`](../../../script/setup/GetTypeAndVersion.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
