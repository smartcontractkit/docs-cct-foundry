---
name: UpdateSiloDesignations
script: script/configure/siloed/UpdateSiloDesignations.s.sol
group: siloed
type: reference
modes: [read]
read_only: true
writes_onchain: false
destructive: false
---

# UpdateSiloDesignations

Silos or unsilos remote chains on a SiloedLockReleaseTokenPool 1.6.x (`updateSiloDesignations`, onlyOwner).

## Inputs

| Env var | Description |
| --- | --- |
| `SILO_CHAINS` | See the script header. |
| `SILO_REBALANCER` | See the script header. |
| `UNSILO_CHAINS` | See the script header. |

## Reference

- Script: [`script/configure/siloed/UpdateSiloDesignations.s.sol`](../../../script/configure/siloed/UpdateSiloDesignations.s.sol)
- Modes: read
- Read-only: true | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
