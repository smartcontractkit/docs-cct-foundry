---
type: reference
---

# Adding a chain and the config tooling

Supporting a new chain is a config edit, not a code change. Tooling under `script/config/` keeps
`config/chains/<name>.json` true to the live [CCIP API](https://api.ccip.chain.link/v2), needing only
`curl` and `jq` (no RPC URL, no keystore, no API key). The golden path is the repo `Makefile`; each
target sets `FOUNDRY_PROFILE=sync` for you. The full command reference (required args, the raw
`forge script` / `bash` each target runs, the `0`/`1`/`2` drift exit-code contract, and the architecture
diagrams) is in [Config architecture](../config-architecture.md).

## Onboard a new chain

Three commands generate and verify `config/chains/<name>.json` from the API:

```bash
make discover FILTER=base            # 1. find the chain in the API catalog, note its NAME + SELECTOR
make add-chain CHAIN=ethereum-testnet-sepolia-base-1 SELECTOR=10344971235874465080   # 2. generate from the API
make doctor CHAIN=ethereum-testnet-sepolia-base-1   # 3. layered verification - re-run until green
```

`CHAIN` is the chain's canonical CCIP selectorName as shown by `make discover` (the API/registry name,
for example `ethereum-testnet-sepolia-base-1`, not a bespoke `base-sepolia`). It becomes the file name
`config/chains/<CHAIN>.json` and is validated against the API. `SELECTOR` is the explicit identity key,
also from `make discover`. Every fetch cross-checks both: a valid-but-wrong selector fails loudly as
`SELECTOR MISMATCH`, and a non-canonical name as `SELECTOR NAME MISMATCH`, instead of silently writing
another chain's contracts.

New chains are discovered automatically from `config/chains/`: `HelperConfig` scans the directory, so no
Solidity edit is needed anywhere. For a newly added chain the `chainNameIdentifier` (and hence the
`rpcEnv` and the `<ID>_TOKEN`/`<ID>_TOKEN_POOL` override prefix) is derived from the selectorName as
UPPER_SNAKE, so it may differ in style from the bundled chains' curated short forms (for example
`AVALANCHE_TESTNET_FUJI`, not `AVALANCHE_FUJI`). `add-chain` prints the exact `chainNameIdentifier` and
`rpcEnv` names it generated, plus your next steps: add the chain's RPC env var to `.env`, review the
generated defaults in the config file, wire a lane with `make add-lane`, and re-run the doctor until it
reports 0 FAIL.

Deploying your token and pool there is the golden path (see [Token operations](tokens.md) and [Token pool
deployment](pools.md)). Then declare the lane policy with `make add-lane LOCAL=<name> REMOTE=<remote>
CAPACITY=<wei> RATE=<wei> BOTH=1`, apply it on-chain (see [Lanes and remote
pools](lanes-and-remotes.md)), and re-run `make doctor`; its lanes rung reconciles the declared policy
against the pool. To retire a lane, `make remove-lane LOCAL=<name> REMOTE=<remote> [BOTH=1]` removes the
declaration; that is a separate step from the on-chain removal (see [Remove a remote
chain](lanes-and-remotes.md#remove-a-remote-chain)), and between the two `make doctor` WARNs that the
on-chain lane is not declared.

Per-field reference: [Config and project-store schema](../config-schema.md). Command and architecture
reference: [Config architecture](../config-architecture.md).

## Which command when

| I want to                                                                    | Run                                                                                            |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| See which chains exist / find a selector                                     | `make discover FILTER=<term>`                                                                  |
| Onboard a new chain                                                          | `make add-chain CHAIN=<name> SELECTOR=<sel>`, then `make doctor CHAIN=<name>`                  |
| Check whether any config drifted from the API (routine; what CI runs weekly) | `make sync-check` (CI/automation: `bash script/config/sync-check.sh` for the 0/1/2 exit codes) |
| Inspect what the API currently has for one chain before changing anything    | `make sync-preview CHAIN=<name>`                                                               |
| Apply the API's current values                                               | `make sync CHAIN=<name>` / `make sync-all`                                                     |
| Declare a lane policy between two chains                                     | `make add-lane LOCAL=<name> REMOTE=<remote> CAPACITY=<wei> RATE=<wei> [BOTH=1]`                |
| Retire a declared lane policy (undo of `add-lane`)                           | `make remove-lane LOCAL=<name> REMOTE=<remote> [BOTH=1]`                                       |
| Bring externally deployed contracts into the registry                        | `make adopt-token CHAIN=<name> TOKEN=<addr> [TOKEN_POOL=<addr>]`                               |
| Deep-verify one chain end to end (human health check)                        | `make doctor CHAIN=<name>`                                                                     |
| Restore canonical formatting after a raw `forge script` run                  | `make fmt-config`                                                                              |

`doctor` and `sync-check` layer rather than overlap: `doctor` is the deep single-chain health check for a
human (schema, identity, drift, RPC, on-chain code, registry warnings, mesh reciprocity, on-chain lane
reconciliation, and declared-`roles{}` authority reconciliation), while `sync-check` is the fleet-wide
drift verdict for routine use and CI.
