---
name: SnapshotChain
script: script/config/SnapshotChain.s.sol
group: config-plane
type: reference
modes: [eoa]
read_only: false
writes_onchain: false
destructive: false
---

# SnapshotChain

**`make snapshot-chain CHAIN=<name>` - backfill the DECLARED authority state FROM chain.** Reads the live role surface (owner/defaultAdmin/getCCIPAdmin/hasRole/TAR getTokenConfig/ dual-generation pool admins/getAllAuthorizedCallers/getAllowList/...) through `RolesSnapshot` and writes the `roles{}` subtree of `project/<selectorName>.json` (preserve-and-replace, the same single-subtree pattern as the `ccip{}` sync).

## Inputs

| Env var | Description |
| --- | --- |
| `FOUNDRY_PROFILE` | See the script header. |

## Reference

- Script: [`script/config/SnapshotChain.s.sol`](../../../script/config/SnapshotChain.s.sol)
- Modes: eoa
- Read-only: false | Writes on-chain: false | Destructive: false

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
