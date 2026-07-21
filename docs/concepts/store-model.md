---
type: concept
---

# The store model: config, project, history

Three stores hold the toolkit's state, each with exactly one writer. Keeping them separate is what makes
a deployment reproducible and a diff meaningful.

## The three stores

| Store | Path | Contents | Writer | Tracked? |
| --- | --- | --- | --- | --- |
| Chain config | `config/chains/*.json` | Pure CCIP facts (router, RMN, selectors), synced from the API | `make sync` / `make add-chain` | git-tracked |
| Project store | `project/[<group>/]<selectorName>.json` | Deploy addresses, lane policy, declared roles | the deploy and config scripts | git-tracked in a fork |
| History | `history/` | Append-only local ledger of every recorded deployment | the deployment recorder | never tracked |

`config/chains` is pure API fact: you never hand-edit it, and `make sync` reproduces it. The project store
is your deployment's identity (what you deployed, where, and who governs it). History is a local audit
trail, not shared.

## One writer per subtree

Each subtree has a single writer, so there is never a merge ambiguity about who owns a value. The API sync
owns `config/chains`. The deploy and config scripts own `project/`. The recorder owns `history/`. A read
path (the resolution ladder, `make doctor`, `make roles-check`) never writes.

## Token groups: partitioning the project store

A project managing several tokens keeps each token group's state in its own subfolder:
`project/<group>/<selectorName>.json`. Every command threads `GROUP=<g>` (`PROJECT_GROUP` for a raw
`forge script`); unset is the flat default (`project/<selectorName>.json`). The isolation guarantee is
that group A operations leave group B untouched.

This matters because the `active.<role>` resolution pointer is single-valued per file: on a two-token
chain in one flat store, zero-export resolution returns the last-deployed pool for both tokens. Groups
give each token its own store and its own pointers. See the
[single-valued active pointer gotcha](../gotchas/index.md#single-valued-active-pointer).

## The redeploy guard

Once an artifact is recorded in the project store, the deploy scripts refuse to redeploy it (naming the
existing address). `FORCE_REDEPLOY=true` overrides the guard. Be aware of the consequence: a forced pool
redeploy leaves the `TokenAdminRegistry` still pointing at the OLD pool, so a set-pool rewire is required
before the new pool is live. See [deployed addresses](../deployed-addresses.md) for the resolution ladder
and the guard in detail.
