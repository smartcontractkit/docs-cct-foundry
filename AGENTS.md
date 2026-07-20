# AGENTS.md

Canonical entry point for AI coding agents (and a quick orientation for humans). This file is the
router; the depth lives under [`docs/`](docs/index.md). Keep answers grounded in these files rather than
guessing, and prefer the deterministic building blocks (make targets and forge scripts) over ad-hoc calls.

## What this repository is

A Foundry toolkit for deploying, registering, wiring, and governing Chainlink CCIP cross-chain tokens
(CCT). It ships composable, idempotent primitives (forge scripts) plus a `make` golden path over them.
Chains are data (`config/chains/*.json`, API-synced), deploy state is a project store (`project/`,
git-tracked once a fork un-gitignores it), and history is an append-only local ledger (`history/`).

## Setup

```bash
npm ci            # installs the Solidity dependencies (contracts) and dev tooling (solhint)
forge build       # compile
```

Requires Foundry, Node + npm, `make`, `bash`, `curl`, and `jq`. Signing uses a Foundry keystore
(`--account <name>`); never put a private key in `.env`. See
[the signing decision record](docs/decisions/0001-keystore-signing.md).

## Build, test, and quality commands

| Command | Purpose |
| --- | --- |
| `forge build --deny warnings` | Compile; zero compiler warnings required. |
| `forge test` | Full test suite (fork tests read RPCs from `.env`). |
| `forge fmt` / `forge fmt --check` | Format Solidity / check formatting. |
| `forge lint` | Foundry's native linter. |
| `npm run lint:sol` | solhint (chainlink-ccip ruleset; must be warning-free). |
| `npm run docs:catalog:check` | Fail if the primitives catalog is stale or a primitive lacks `@notice`. |

## The golden path (make)

`make help` lists every target. The common flow:

```bash
make discover                                   # search the CCIP API chain catalog
make add-chain CHAIN=<selectorName> SELECTOR=<sel>   # generate config/chains/<name>.json from the API
make deploy-token CHAIN=<name>                   # deploy a token (params via env; keystore + RPC resolved from the chain file)
make deploy-pool CHAIN=<name>                    # deploy its BurnMint pool
make doctor CHAIN=<name>                         # layered verification
```

`make deploy-new-chain CHAIN=<name> SELECTOR=<sel>` runs `add-chain -> deploy-token -> deploy-pool ->
doctor` end to end. Every make target documents the raw `forge script` it wraps as the escape hatch.

## The primitives catalog (start here to select a building block)

- Machine-readable index: [`docs/primitives/catalog.json`](docs/primitives/catalog.json) - every
  user-facing script and make target, with modes, safety flags (`read_only`, `writes_onchain`,
  `destructive`), and inputs. Query this to pick the right primitive and wire its inputs.
- Human pages: [`docs/primitives/`](docs/primitives/) - one page per primitive, generated from the
  scripts so they cannot drift. Regenerate with `npm run docs:catalog`.

## Conventions and guardrails

- **Signing:** Foundry keystore only (`--account`), or `--ledger`/`--trezor`. No `PRIVATE_KEY` in `.env`.
- **Modes:** most write primitives are mode-parameterized. `MODE=safe` emits a Safe batch instead of
  broadcasting; the default is EOA. See [governance modes](docs/governance-modes.md).
- **Stores (one writer each):** `config/chains/*.json` (pure API facts, synced) vs
  `project/[<group>/]*.json` (deploy addresses, lanes, roles) vs `history/` (append-only, never tracked).
- **Token groups:** thread `GROUP=<g>` (`PROJECT_GROUP` for raw `forge script`) to manage several tokens
  in one clone; unset is the flat default.
- **Redeploy guard:** a deployed artifact is not redeployed unless `FORCE_REDEPLOY=true` (which then
  leaves the `TokenAdminRegistry` pointing at the old pool until rewired).
- **Test scratch discipline:** test write targets use `zz-scratch-*` / `zz-tt-*` / `local-*` names only,
  never a real chain name; a green run leaves zero residue.

## Where to look

- [`docs/index.md`](docs/index.md) - the full documentation map.
- Guides (how to accomplish an outcome), reference (schemas, version matrices, env vars), concepts
  (why it works), and the learnings layer (troubleshooting, gotchas, decisions) all hang off the index.
