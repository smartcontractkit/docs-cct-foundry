# Roles: the authority durable store and reconciliation

> Owner: docs-cct-foundry maintainers · Last reviewed: 2026-07-15 · Applies to: the `project/` layout
> (schema 3).

This deployment's **privileged authority** - who can mint, burn, re-point the pool, throttle a lane,
move liquidity, or change which verifiers a message requires - is declared in the `roles{}` subtree of
each chain's project store (`project/<selectorName>.json`), and reconciled against the live chain by
tooling. This doc makes the model operationally unambiguous: what the store is, which command reads
and which writes, what to do when they disagree, and exactly how much assurance a clean check gives.

For the field-by-field schema of `roles{}`, see
[`config-schema.md` → The `roles{}` subtree](./config-schema.md#the-roles-subtree---declared-authority-not-api-fact).
This document is the operator's runbook for the read-only reconcile engine (`RolesProbes` /
`RolesSnapshot` / `RolesAuditor`, `make snapshot-chain`, `make roles-check`, and the doctor's roles
rung). The **EOA → Safe roles-handoff ceremony** (grant-new-before-revoke-old, the two-step accepts,
revoke-last, and the live completeness matrix) is documented in its own section when that half lands;
this doc covers the durable store and its reconciliation.

## The mental model, stated plainly

- **`roles{}` in the project store is the DECLARED intent** - the authority the chain _should_ have. When
  a fork tracks `project/`, it is reviewed in a pull request, so a change to who controls the deployment is
  a diff a human approved.
- **The chain is reality** - who _actually_ holds each role right now.
- **"Reconcile" means DETECT divergence between the two and report it.** It is **not** an auto-fix:
  the tooling never moves a role. It tells you the declaration and the chain disagree, and names the
  field; you decide which side is wrong.

## The authority map

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#E8EDFB','primaryBorderColor':'#375BD2','primaryTextColor':'#1A2B6B','lineColor':'#375BD2','fontFamily':'ui-sans-serif, system-ui, sans-serif'}}}%%
flowchart TB
  subgraph GOV["governance{} (optional) — the recipient of a handoff"]
    SAFE["Safe<br/>threshold + owners"]
    TL["TimelockController<br/>minDelay + proposers/cancellers/executors"]
  end

  subgraph TOKEN["token — template-dispatched"]
    DA["defaultAdmin / owner / defaultAdmins{}<br/>(top-level admin)"]
    CA["ccipAdmin<br/>(TAR registration authority)"]
    BMA["burnMintRoleAdmins{}<br/>(admins MINTER/BURNER — crosschain)"]
    MB["minters{} / burners{}<br/>(MINTER_ROLE / BURNER_ROLE)"]
  end

  subgraph POOL["pool — dual-generation"]
    PO["owner (config authority)"]
    RLA["rateLimitAdmin (fast throttle)"]
    FA["feeAdmin (2.0.0)"]
    HK["hooks pointer (2.0.0)"]
  end

  subgraph TAR["TokenAdminRegistry"]
    ADMIN["administrator<br/>(the cutover / onlyTokenAdmin authority)"]
  end

  subgraph LB["lockbox (v2 LR) / rebalancer (v1 LR)"]
    LBO["owner + authorizedCallers"]
  end

  subgraph HOOKS["hooks (security-critical)"]
    HO["owner + policyEngine<br/>(controls which CCVs a lane requires)"]
  end

  SAFE -.->|holds, post-handoff| DA
  SAFE -.-> CA
  SAFE -.-> BMA
  SAFE -.-> PO
  SAFE -.-> RLA
  SAFE -.-> ADMIN
  SAFE -.-> LBO
  SAFE -.-> HO
  BMA -->|role-admin of| MB
  DA -->|owner-gated| CA

  classDef out fill:#FFFFFF,stroke:#375BD2,stroke-dasharray:4 3,color:#1A2B6B;
  TAROWNER["TAR CONTRACT owner\n= network operator (Chainlink) — OUT OF SCOPE"]:::out
```

The reconcile engine reads every solid-outlined slot. The dashed **TAR contract owner** is the
network operator's authority (self-service registration via `RegistryModuleOwnerCustom`), deliberately
never read and never a FAIL.

## The two directions, and which one writes

| Command                            | Reads                        | Writes                                                      | Exit contract                                                 |
| ---------------------------------- | ---------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------- |
| `make roles-check CHAIN=<name> [GROUP=<g>]`    | live chain + the declaration | **nothing**                                      | `0` clean / `1` drift (names the field) / `2` RPC unavailable |
| `make snapshot-chain CHAIN=<name> [GROUP=<g>]` | live chain                   | **only** the `.roles` subtree of that chain's project store | writes the declaration; canonicalizes the file    |

- **`make roles-check` is READ-ONLY.** It reads the live chain, compares to the declaration, prints one
  aligned `[PASS]`/`[FAIL]`/`[WARN]`/`[SKIP]` line per field, and exits `0`/`1`/`2`. It **never** writes
  a local file and never broadcasts. `make doctor CHAIN=<name>` runs the same auditor as its roles rung.
  (The `0/1/2` exit contract lives in `script/config/roles-check.sh`; GNU make remaps any recipe failure
  to `2`, so `make roles-check` is pass/fail only - **CI calls the script directly** for the real codes,
  the same pattern as `sync-check.sh`.)
- **`make snapshot-chain` is the ONLY writer.** It backfills the declaration FROM the chain
  (preserve-and-replace on the `.roles` subtree only), for the initial bootstrap or an intentional
  resync. Same no-silent-writeback rule as `lanes{}`: a read check never edits your files, and the one
  writer is an explicit, reviewed command.

Bootstrap a chain that has no `roles{}` yet:

```bash
make snapshot-chain CHAIN=ethereum-testnet-sepolia    # writes the .roles block from the live chain
git diff project/ethereum-testnet-sepolia.json        # review who holds what — the audit artifact (once a fork tracks project/)
make roles-check CHAIN=ethereum-testnet-sepolia        # should now report CLEAN (exit 0)
```

To prove a non-enumerable minter/burner list is complete (not just a candidate seed), run the event
scan. It marks the list `complete: true` only if the `eth_getLogs` scan succeeds over the range **and**
you pass a `fromBlock` at or before the token's deploy block (otherwise holders granted before
`fromBlock` and never re-touched are missed). The snapshot records the block it scanned from as
`scannedFromBlock` next to `complete`, so the completeness is legible as a proof _as of that block_:

```bash
SCAN_FROM_BLOCK=<token-deploy-block> make snapshot-chain CHAIN=ethereum-testnet-sepolia
```

A failed scan (an RPC that caps the `eth_getLogs` range) degrades to candidates with a logged SKIP and
`complete: false` - never a silently partial "complete" list. **`complete: true` is a point-in-time
proof, not a live invariant:** a grant made _after_ `scannedFromBlock`..snapshot is not reflected until
you re-snapshot (or run `roles-check` with `SCAN_FROM_BLOCK`, see the additive-detection note below).

## Token-group scope

A clone can hold several token groups, each in its own project-store directory (see
[`config-schema.md`](./config-schema.md#the-project-store---projectselectornamejson)). `GROUP=<g>` scopes an
authority command to one group's store (`project/<g>/<selectorName>.json`); unset is the flat default group,
with one deliberate exception for the read check:

- **`make snapshot-chain CHAIN=<name> GROUP=<g>`** and **`make doctor CHAIN=<name> GROUP=<g>`** each act on
  the one named group (unset = the default group).
- **`make roles-check GROUP=<g>`** scopes to that one group. With **`GROUP` unset it does not stop at the
  default group** - it reconciles the default group AND every `project/<group>/` subdirectory, prefixing
  each result line with `[group: <g>]` (the default group is labelled `[group: default]`), so a grouped
  token is never silently skipped.
- **`make roles-check-all`** sweeps every chain that declares `roles{}` across all token groups, under the
  same exit contract as `roles-check`.

## The drift-response runbook

When `make roles-check` reports **drift** (exit `1`, naming the exact field), **triage severity first,
then decide which side is wrong:**

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#E8EDFB','primaryBorderColor':'#375BD2','primaryTextColor':'#1A2B6B','lineColor':'#375BD2','fontFamily':'ui-sans-serif, system-ui, sans-serif'}}}%%
flowchart TD
  D["roles-check reports drift<br/>(names the field)"] --> S{"Did a GOVERNANCE-CRITICAL slot move<br/>to an address OUTSIDE the known-good set?<br/>(pool.owner, TAR administrator,<br/>a mint/burn holder, hooks.owner/policyEngine)"}
  S -->|"Yes — possible compromise"| C["CONTAIN FIRST:<br/>throttle the affected lane via rateLimitAdmin now,<br/>freeze any pending two-step transfer,<br/>THEN investigate root cause"]
  S -->|"No — a benign/expected field"| Q
  C --> Q{"Was this on-chain change<br/>INTENDED?"}
  Q -->|"No — the CHAIN drifted<br/>(unauthorized role move)"| R1["Remediate ON-CHAIN<br/>(transfer the role back / setPool back /<br/>setDynamicConfig) until chain == declaration"]
  Q -->|"Yes — the declaration is stale<br/>(a deliberate authority change)"| R2["Update the DECLARATION<br/>via a reviewed edit or snapshot-chain,<br/>and PR the diff"]
  R1 --> V["make roles-check → exit 0"]
  R2 --> V
```

- **(0) Containment first (severity triage).** Before deciding intended-vs-unintended, check _what_
  drifted. If `pool.owner`, `tokenAdminRegistry.administrator`, a mint/burn holder, or
  `hooks.owner`/`policyEngine` moved to an address outside your known-good set, treat it as a **potential
  compromise**: use the emergency-throttle authority (`rateLimitAdmin`, held on the Safe by convention -
  the auditor WARNs when it is not) to **throttle the affected lane immediately** and freeze any pending
  two-step transfer, _then_ root-cause. A rogue mint/burn or owner move is exfiltration risk; contain
  before you investigate.
- **(a) The CHAIN drifted** - an unauthorized role move. Remediate **on-chain** (transfer the role
  back, `setPool` back, a corrective `setDynamicConfig`, or re-run the handoff step) until the live chain
  matches the declared intent, then re-check. Keep the old known-good holder handy as the rollback target.
- **(b) The change was INTENDED** - a deliberate authority change (e.g. you moved a role to a new
  governance address on purpose). Update the **declaration** through a reviewed edit or
  `make snapshot-chain`, and PR the diff so the new intent is recorded and approved.

`make doctor`'s roles rung and the scheduled CI `roles-check` (in `.github/workflows/config-drift.yml`,
non-blocking) keep surfacing the drift as a `[FAIL]`/`::warning::` until it is reconciled one way or the
other. Reconciling means the two agree again - either the chain was fixed or the declaration was.

### `setDynamicConfig` router-preservation footgun

`rateLimitAdmin` and `feeAdmin` are both set through `setDynamicConfig(router, rateLimitAdmin,
feeAdmin)` - there is no standalone `setRateLimitAdmin` on 2.0.0. The setter **rewrites the pool's
router**, so any remediation that changes `rateLimitAdmin`/`feeAdmin` must **read the current router
live, pass it back unchanged, and assert it byte-identical pre and post.** Miss it and you silently
re-point the pool's router while "just" changing an admin. The handoff/remediation builders encode this
guard; when you remediate by hand, preserve the router explicitly.

## The honest-coverage caveat

**A CLEAN `roles-check` proves only what the engine can READ.** Read exactly this much assurance into a
green run, no more.

### The two failure directions are NOT covered equally

For a role-holder list, there are two ways it can be wrong, and the engine detects them very differently:

- **A declared holder was REVOKED** (someone you trusted lost the role): **always detected**, for every
  template - each declared holder is a direct `hasRole`/getter point-check.
- **An UNDECLARED holder was ADDED** (a rogue `MINTER_ROLE`/`DEFAULT_ADMIN_ROLE` grant): **detected only
  when the live set is knowable** -
  - `factory` and any `AccessControlEnumerable` token → **always** (two-sided set compare against the
    live enumeration);
  - `crosschain` / `burnmint` (non-enumerable) → **only when you run `roles-check` with
    `SCAN_FROM_BLOCK`** (an opt-in event-scan two-sided compare). Without it, the default reconcile
    verifies declared-holders-hold and **WARNs** that additive grants are unverified - it never
    reports a silent CLEAN over the gap, even when the list is `complete: true` (that completeness was
    proven at snapshot time, not now).

So: **a `crosschain`/`burnmint` CLEAN on a default (no-scan) run does not prove that no rogue mint/admin
grant exists.** For that assurance, run `SCAN_FROM_BLOCK=<deploy-block> make roles-check CHAIN=<name>`
on an RPC that serves the log range, which turns the additive check into a hard FAIL.

### Coverage by surface

- **Fully covered for any token** (CCIP-side authority, all direct getters, both directions): the
  TokenAdminRegistry `administrator`, the pool `owner` / `rateLimitAdmin` / `feeAdmin`, the lockbox
  `owner` / `authorizedCallers`, the hooks `owner` / `policyEngine`, the rebalancer (v1), and the token's
  admin-registration point - `token.owner()`, `getCCIPAdmin()`, or the AccessControl `DEFAULT_ADMIN_ROLE`
  (declared holders verified by `hasRole`). Governance-critical single-holder or enumerable slots read
  directly, never at the mercy of RPC log limits.
- **Token-internal multi-holder lists** (mint/burn, multi-holder default-admin): revoke always detected;
  additive detected per the direction rule above (enumerable always, non-enumerable only with
  `SCAN_FROM_BLOCK`).
- **NOT proven for a `byo` token**: a BYO token's token-internal mint/burn/admin rights are
  declaration-backed with `complete: false` and cannot be event-scanned (its deploy block is unknown to
  the engine). **A clean check does NOT prove a BYO token's mint/burn rights are safe** - only its
  universal admin points (`owner`/`ccipAdmin`/`DEFAULT_ADMIN_ROLE` point-checks) are verified.

## The snapshot forward-intent footgun

`make snapshot-chain` records an **already-executed** state: it backfills the declaration FROM the current
chain. It cannot express a change you _intend_ to make but have not executed yet. So if you are about to
move a role and want the declaration to lead the change (declare-then-execute), that first edit is a
**hand edit**, not a snapshot - running `snapshot-chain` before the on-chain move would silently overwrite
your forward-intent declaration back to the current (pre-change) chain state. Use `snapshot-chain` for the
initial bootstrap and for a _post-hoc_ resync after an intended change has landed on-chain; use a reviewed
hand edit when the declaration must precede the on-chain move.
