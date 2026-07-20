# Chain config and project-store schema

Per-chain state lives in **two files, both keyed by the canonical CCIP selectorName**:

- **`config/chains/<selectorName>.json`** - pure API/chain facts (the `ccip{}` addresses, API-served
  identity/metadata, the hand-authored keys, and the join keys). Git-tracked.
- **`project/<selectorName>.json`** - the **project store**: three subtrees (`addresses{}`, `lanes{}`,
  `roles{}`) plus `"schema": 3`. Gitignored in this template repo; a fork tracks it (see
  [The project store](#the-project-store---projectselectornamejson)).

This repo treats **CCIP chain metadata as DATA, not code**. Every chain selector, router, and CCIP
infra address the scripts need is read from `config/chains/<selectorName>.json` at build/test time via
`vm.parseJson*` (`src/config/ChainConfig.sol`). There are **no hardcoded selectors or CCIP addresses**
in Solidity: `HelperConfig` discovers the chain list by scanning the `config/chains` directory
(`vm.readDir`), so adding a chain - or updating a CCIP address - is a reviewed config edit with zero
Solidity changes.

The operational how-to (discover → add-chain → sync → doctor, and the "which command when" table) lives
in the [README](../README.md#configuration); the `make`-command reference and the layered architecture
(with diagrams) are in **[`config-architecture.md`](config-architecture.md)**. This document is the
**field-by-field reference** for both files.

## The file name IS the canonical CCIP selectorName

Each file is named by, and carries a `name` field equal to, the **canonical CCIP selectorName** from the
[`chain-selectors`](https://github.com/smartcontractkit/chain-selectors) registry - the one identifier
the CCIP REST API (`GET /v2/chains/{selector}` → `.name`), CLD, Atlas, the directory URL leaf, and
`ccip-cli` all key on. So the files are `ethereum-testnet-sepolia.json`,
`ethereum-testnet-sepolia-mantle-1.json`, `0g-testnet-galileo-1.json`, `plume-testnet-sepolia.json`,
`ink-testnet-sepolia.json`, and `solana-devnet.json` - **not** bespoke short slugs like `ethereum-sepolia`.

`name` is the value you pass as `CHAIN=` to every `make` target. The sync **validates** it: after each API
fetch it asserts the config `name` equals the API selectorName and reverts `SELECTOR NAME MISMATCH`
otherwise (a sibling to the numeric `SELECTOR MISMATCH` chainId guard). `make add-chain` refuses any
`CHAIN=` that is not the canonical selectorName. This is the portable identity key for **non-EVM** chains
too, whose `chainId` is a placeholder `"0"` the chainId guard cannot verify (see below).

## One writer per subtree

Each subtree of each file has a **single writer**, so a change is always attributable. In `config/chains`
(git-tracked) that attribution is a git diff. In the project store it is the writing command; a fork that
tracks `project/` gets a git diff there too (see [The project store](#the-project-store---projectselectornamejson)).

| File            | Subtree / field group                                                                                                                   | Owner                                          | Sole writer                                                                                                            |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `config/chains` | `ccip{}` + the API-served identity/metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`) | the CCIP REST API                              | the **API sync** (`make add-chain` / `sync` / `sync-all`) - never by hand                                              |
| `config/chains` | the hand-authored keys the API serves nothing for (`chainNameIdentifier`, `rpcEnv`, the optional `verifier{}` block)                    | repo maintainers                               | a **reviewed hand edit** in a pull request                                                                             |
| `config/chains` | immutable join keys (`name`, `chainSelector`, `chainId`)                                                                                | the chain-selectors registry                   | seeded at `add-chain`, then **guard-validated** by the sync (never rewritten)                                          |
| `project`       | `addresses{}` (the deployed-address registry sub-store)                                                                                 | the deployer                                   | the **deploy scripts** (one `DeploymentRecorder` call → `RegistryWriter`) and **`make adopt-token`**, on `--broadcast` |
| `project`       | `lanes{}` (which remotes this pool connects to, at what outbound rate limits)                                                           | the token owner (policy)                       | **`make add-lane`** / **`make remove-lane`** or a reviewed hand edit - **never the API sync**                          |
| `project`       | `roles{}` (the privileged-authority surface: who holds token/pool/TAR/lockbox/hooks roles + optional `governance{}`)                    | the project's security owner (declared intent) | **`make snapshot-chain`** (backfill FROM chain) or a reviewed hand edit; `make roles-check` only READS it              |
| `project`       | `poolPolicy{}` (pool-scoped values: the pool-global `ccvThreshold` and the allowed-finality `finality{}` block)                         | the token owner (policy)                       | a **reviewed hand edit** only (no flag surface, no scripted writer, no silent writeback); `make fmt-config` repairs form |

The sync enforces this structurally: `SyncCcipConfig.run` writes **only** the API-served fields: the
`.ccip` subtree (`vm.writeJson(json, path, ".ccip")`) plus the five identity/metadata keys the CCIP REST
API serves, each a targeted `vm.writeJson(value, path, ".<key>")`. So the hand-authored keys
(`chainNameIdentifier`, `rpcEnv`, the optional `verifier{}` block) are preserved untouched and the join keys are validated,
not overwritten. The sync **never touches the project store** at all. Each project-store writer mirrors the
same discipline from its side: `make add-lane` writes **only** `.lanes` (`vm.writeJson(lanes, path, ".lanes")`),
`RegistryWriter` writes **only** `.addresses`, and `make snapshot-chain` writes **only** `.roles`
(`SnapshotChain.s.sol` → `vm.writeJson(roles, path, ".roles")`, preserve-and-replace on that subtree only) -
each seeds the full skeleton first if the file is absent. **The rule of thumb: if a field exists on
`GET /v2/chains/{selector}`, the sync sources it from the API; you never hand-type it. If a field is policy,
authority, or a deployed address, the owning command writes it into the project store, and the sync never
will.** See [The `roles{}` subtree](#the-roles-subtree---declared-authority-not-api-fact) below and the
operational runbook in [`docs/roles.md`](./roles.md).

## config/chains file - every field (pure API facts)

`config/chains/<selectorName>.json` carries **only** chain facts: the API-synced `ccip{}` and
identity/metadata, the hand-authored keys, and the join keys. Owner policy (`lanes{}`), authority
(`roles{}`), and deployed addresses (`addresses{}`) are **not** here - they live in the project store (see
[The project store](#the-project-store---projectselectornamejson)).

Example (`config/chains/ethereum-testnet-sepolia.json`), grouped by writer:

```jsonc
{
  // ── join keys (seeded at add-chain, then guard-validated by the sync; never rewritten) ───
  "name": "ethereum-testnet-sepolia", // canonical CCIP selectorName; == file basename; the CHAIN= arg
  "chainId": "11155111", // native chain id, quoted STRING (see big-int note); "0" for non-EVM
  "chainSelector": "16015286601757825753", // uint64 CCIP selector, quoted STRING; the primary join key

  // ── API-synced identity + metadata (sourced from GET /v2/chains/{selector}; never hand-edit) ──
  "displayName": "Ethereum Sepolia", // <- chain.displayName; human label for logs / output links
  "chainFamily": "evm", // <- chain.chainFamily (lowercased); dispatches EVM vs non-EVM
  "environment": "testnet", // <- chain.environment ("testnet" | "mainnet")
  "explorerUrl": "https://sepolia.etherscan.io", // <- chainMetadata.explorer.url; output/verification links
  "nativeCurrencySymbol": "ETH", // <- chainMetadata.nativeCurrency.symbol; native gas-token symbol

  // ── ccip{} : API-synced (overwritten by the sync; never hand-edit) ───────────
  "ccip": {
    "router": "0x0BF3dE8c...", // CCIP Router - entrypoint for ccipSend / offRamp
    "rmnProxy": "0xba3f6251...", // RMN (Risk Management Network) proxy / ARMProxy
    "tokenAdminRegistry": "0x95F29FEE...", // TokenAdminRegistry - maps token → its pool + admin
    "registryModuleOwnerCustom": "0xa3c796d4...", // RegistryModuleOwnerCustom - claim-admin registry module
    "feeQuoter": "0x8632C302...", // FeeQuoter - quotes CCIP fees (reference)
    "tokenPoolFactory": "0x2067C044...", // TokenPoolFactory - deploys standard pools (reference)
    "link": "0x779877A7...", // LINK token (the LINK fee token on this chain)
    "feeTokens": ["0xc4bF5CbD...", "0x779877A7...", "0x097D90c9..."] // accepted CCIP fee tokens (reference)
  },

  // ── hand-authored (the API serves nothing for these; reviewed in a PR, preserved by sync) ──
  "chainNameIdentifier": "ETHEREUM_SEPOLIA", // UPPER_SNAKE env-var prefix: <ID>_RPC_URL, <ID>_TOKEN, <ID>_TOKEN_POOL
  "rpcEnv": "ETHEREUM_SEPOLIA_RPC_URL" // name of the env var holding this chain's RPC URL
  // optional "verifier": { "type": "...", "url": "..." } - explorer-verification backend (absent = Etherscan v2)
}
```

### Field reference

"Written by" values: **API sync** = sourced + refreshed + drift-checked from the CCIP REST API;
**API sync (guard)** = seeded at `add-chain` then validated (not rewritten) every sync; **hand** = the
API serves nothing for it, so a reviewed PR owns it and the sync preserves it verbatim.

| Field                            | Type / format                         | Written by           | API source (if any)                               | Consumed by                                   |
| -------------------------------- | ------------------------------------- | -------------------- | ------------------------------------------------- | --------------------------------------------- |
| `name`                           | string (canonical selectorName)       | **API sync (guard)** | `chain.name`                                      | file key + basename; validated by the sync    |
| `chainId`                        | quoted decimal string (`"0"` non-EVM) | **API sync (guard)** | `chain.chainId` (EVM; `"0"` placeholder non-EVM)  | `ChainConfig.chainId`; sync identity guard    |
| `chainSelector`                  | quoted `uint64` string                | **API sync (guard)** | `chain.chainSelector`                             | `ChainConfig.load`; the primary join key      |
| `displayName`                    | string                                | **API sync**         | `chain.displayName`                               | `ChainConfig.load` → `chainName`; log output  |
| `chainFamily`                    | `"evm"` \| `"svm"`                    | **API sync**         | `chain.chainFamily` (lowercased)                  | `ChainConfig.load`; EVM/non-EVM dispatch      |
| `environment`                    | `"testnet"` \| `"mainnet"`            | **API sync**         | `chain.environment`                               | provenance                                    |
| `explorerUrl`                    | URL string                            | **API sync**         | `chainMetadata.explorer.url`                      | `ChainConfig.load`; output/verification links |
| `nativeCurrencySymbol`           | string                                | **API sync**         | `chainMetadata.nativeCurrency.symbol`             | `ChainConfig.load`                            |
| `ccip.router`                    | address                               | **API sync**         | `chainConfig.router` (active)                     | `ChainConfig.load` → `router`                 |
| `ccip.rmnProxy`                  | address                               | **API sync**         | `chainConfig.rmn` (active)                        | `ChainConfig.load` → `rmnProxy`               |
| `ccip.tokenAdminRegistry`        | address                               | **API sync**         | `chainConfig.tokenAdminRegistry` (active)         | `ChainConfig.load`                            |
| `ccip.registryModuleOwnerCustom` | address                               | **API sync**         | `chainConfig.registryModule` (active)             | `ChainConfig.load`                            |
| `ccip.feeQuoter`                 | address                               | **API sync**         | `chainConfig.feeQuoter` (active)                  | reference (drift-checked)                     |
| `ccip.tokenPoolFactory`          | address                               | **API sync**         | `chainConfig.tokenPoolFactory` (active)           | reference (drift-checked)                     |
| `ccip.link`                      | address                               | **API sync**         | `chainConfig.feeTokens[symbol==LINK]`             | `ChainConfig.load` → `link`                   |
| `ccip.feeTokens`                 | address[]                             | **API sync**         | `chainConfig.feeTokens[].tokenAddress`            | reference (drift-checked)                     |
| `chainNameIdentifier`            | UPPER_SNAKE string                    | hand                 | — (not in the API)                                | `ChainConfig.load`; the `<ID>_*` env prefix   |
| `rpcEnv`                         | env-var name string                   | hand                 | — (not in the API)                                | fork setup; the doctor's RPC rung             |
| `verifier.type`                  | `"etherscan"` \| `"blockscout"` \| `"sourcify"` (optional block) | hand | (not in the API)                           | `script/config/verify-args.sh` (forge verifier flags) |
| `verifier.url`                   | URL string (required for `blockscout` only) | hand           | (not in the API)                                  | `script/config/verify-args.sh` (`--verifier-url`) |

The optional `verifier{}` block selects the chain's explorer-verification backend. Absent means the
Etherscan family: bare `--verify` works because forge resolves the Etherscan v2 endpoint from the chain
id, with a warned fallback to Sourcify for a chain Etherscan v2 does not serve. `"blockscout"` requires
`url` (the instance API endpoint, usually `<explorerUrl>/api`); `"sourcify"` is keyless and needs no URL.
`make doctor CHAIN=<name>` validates it: an unknown `type` FAILs, `blockscout` without a `url` FAILs, and
so does a stray `confirmations` key (not part of the schema). See
[README → Verifying Deployed Contracts](../README.md#verifying-deployed-contracts).

The `lanes.<remote>` field rows (`remoteSelector`, `capacity`, `rate`, `inbound`, the `v2` blocks) live
with the subtree in the project store - see
[The `lanes{}` subtree](#the-lanes-subtree---owner-policy-not-api-fact). Pool-scoped policy values
(`ccvThreshold`, `finality{}`) live there too, in the `poolPolicy{}` block - a `ccvThreshold` key left in
a config file is a schema-rung FAIL naming the move (see
[The `poolPolicy{}` block](#the-poolpolicy-block---pool-scoped-policy)).

> **`chainNameIdentifier`/`rpcEnv` are DERIVED for newly added chains.** `make add-chain` seeds
> `chainNameIdentifier` as UPPER_SNAKE of the selectorName (e.g. `avalanche-testnet-fuji` →
> `AVALANCHE_TESTNET_FUJI`) and `rpcEnv` as `<chainNameIdentifier>_RPC_URL`, so a fresh chain's names
> may differ in style from the six bundled chains' hand-curated SHORT forms (`ETHEREUM_SEPOLIA`, not
> `ETHEREUM_TESTNET_SEPOLIA`). A selectorName that starts with a digit gets a leading `_`, because a
> POSIX shell env-var name cannot start with a digit: `0g-testnet-galileo-1` derives
> `_0G_TESTNET_GALILEO_1` and the settable `rpcEnv` `_0G_TESTNET_GALILEO_1_RPC_URL`. You cannot always
> guess the derived names, so `add-chain` **prints the exact `chainNameIdentifier` and `rpcEnv` it
> generated** in its next-steps output. Override at generation time with the `CHAIN_NAME_IDENTIFIER` /
> `RPC_ENV` env vars; these keys are hand-authored thereafter (the sync never rewrites them).
>
> **The bundled `0g-testnet-galileo-1` is the frozen exception.** For any NEW digit-leading chain the
> derivation above prefixes `_`, and the doctor WARNs when a config's `rpcEnv` is not a valid shell
> identifier, so the RPC-gated rungs never SKIP silently. The bundled `0g-testnet-galileo-1` predates
> that behavior: it carries `chainNameIdentifier: 0G_GALILEO_TESTNET`, so its `<ID>_*` override vars
> (`0G_GALILEO_TESTNET_TOKEN`, `0G_GALILEO_TESTNET_TOKEN_POOL`, ...) are digit-leading. `export 0G_...=`
> is refused by the shell, and forge's `.env` autoload silently stops parsing the file at a digit-leading
> key (every later `.env` line is then ignored too). Its `rpcEnv` is the hand-curated shell-safe
> `ZERO_G_TESTNET_RPC_URL` and belongs in `.env` as usual. Do not put `0G_...=` lines in `.env`; pass
> those vars inline via `env`: `env '0G_GALILEO_TESTNET_TOKEN=0x...' forge script ...`.

> **Big integers are quoted STRINGS.** `chainSelector` (uint64) and `chainId` exceed JSON's safe integer
> range (2^53), so they are stored as quoted decimals and read with `vm.parseJsonUint`, which parses
> quoted decimals. Never store them as bare JSON numbers - precision is silently lost.

> **Targeted key reads, not whole-struct decode.** `ChainConfig` reads by path (`.ccip.router`,
> `.chainSelector`, …), so it is order-independent and robust to the alphabetical key reordering that
> `vm.writeJson` and the canonical `jq --indent 2 -S` format perform.

## Manual address planes (`configSource: "manual"`)

Every `ccip{}` address is normally sourced from the CCIP REST API. Some deployments are not served by
that API - for example a pre-release or otherwise non-production CCIP deployment that reuses the SAME
real chain selectors and chainIds but a DIFFERENT Router / RMN proxy / TokenAdminRegistry /
RegistryModuleOwnerCustom / FeeQuoter set. For those, one clone = one address plane, declared in data:
a reviewer hand-edits the existing `config/chains/<selectorName>.json`, replaces the `ccip{}` block with
that plane's addresses, and stamps a single optional key `"configSource": "manual"`. Absent, it reads as
`"api"` - byte-identical to a config that never carried the key.

The marker flips the declared WRITER of the `ccip{}` subtree from the API to a reviewed hand edit (the
[one-writer table](#one-writer-per-subtree) gains a row, not an exception), and every API-coupled tool
reacts by name:

- `make sync` / `make sync-all` REFUSE to write a manual chain (a named `[sync] SKIP <name> -
  configSource is manual` line, exit 0) - the API sync can never overwrite the hand-maintained
  addresses back to the API's plane. `configSource` must be exactly `"api"` or `"manual"`; an unrecognized value
  (a typo like `"Manual"`) is refused with a named error, never quietly treated as `"api"` and
  overwritten (fail-closed), and the doctor's schema rung FAILs it too.
- `make sync-check` treats a manual chain as SKIP, so the CI drift sweep stays green and honest.
- `make doctor`'s API rung is a named SKIP plus one WARN (the residual risk: an address change on this
  plane is not API-detectable, so on a failure re-verify the `ccip{}` addresses against your address
  source). Every other rung (schema, RPC, on-chain code, TAR, mesh, lanes, roles) is a pure RPC / file
  read and runs unchanged. With an RPC configured, the on-chain rung also logs the FeeQuoter's
  `typeAndVersion` as a quick check that the plane is the intended CCIP version (the FeeQuoter, OnRamp,
  and OffRamp carry the discriminating version string; the Router reports the same string across
  versions, so it is never the version probe).
- `make add-lane` and the doctor's mesh rung REFUSE a cross-plane lane - one API chain and one manual
  chain - naming both chains and both `configSource` values. A lane must connect two chains on the same
  address plane.

The cross-plane refusal runs before the non-EVM reciprocity exemption, so a manual plane whose
destination is a non-EVM chain (Solana, Aptos) must mark that chain's config `manual` too; the sync's
manual refusal then also covers that chain's metadata refresh.

Hand-editing a `ccip{}` block WITHOUT the marker stays loud: `make doctor` reports DRIFT, `make
sync-check` goes red, and the next `make sync` reverts it. The drift error names `configSource: "manual"`
as the intended path when the addresses are a deliberate non-API plane rather than stale.

`make add-chain` stays API-only: a manual chain is never CREATED by tooling, only converted by a
reviewed edit. This repo ships **no** address preset for any such plane - those addresses change on
redeploys and no external service tracks them, so the mechanism is shipped and the data never is. Keep the whole plane in a
branch (the reviewed diff is the audit trail of which addresses were in use when); the documented pattern
is one git worktree per plane.

## The project store - `project/<selectorName>.json`

The project store holds all per-chain state this repo owns, in three subtrees plus a version field, with
**one writer each**:

```jsonc
{
  "addresses": { "active": {}, "deployments": {} },
  "lanes": {},
  "roles": {},
  "schema": 3
}
```

That skeleton is what every writer seeds when it first touches a chain (a user's first touch is often
`make add-lane` or `make snapshot-chain`, not a deploy), so no command hits a raw `vm.writeJson`-on-missing
cheatcode revert. `"schema": 3` is the version integer future migrations dispatch on. The file is keyed by
the canonical **selectorName** (the `config/chains` basename), so two non-EVM chains that both report
`chainId "0"` never collide - each resolves to its own `project/<selectorName>.json`, and no `project/0.json`
is ever created.

**Tracking.** This template repo **gitignores `project/`** - it ships no real deployment addresses, only the
concrete example `project/ethereum-testnet-sepolia.example.json`. A downstream **fork should un-gitignore
`project/`** so its lanes, roles, and addresses become one reviewed, git-versioned, team-shared source of
truth: track public data only (addresses + reviewed policy and authority), **never secrets** (a lint FAILs a
secret-shaped value). See [`deployed-addresses.md`](deployed-addresses.md#tracking-rule-template-vs-fork).

**Token groups (multiple tokens in one clone).** A clone can hold N independent token groups, each in its
own subdirectory: `project/<group>/<selectorName>.json`. `GROUP=<name>` (the make var, threaded to the
scripts as `PROJECT_GROUP`) selects one; an unset group is the **default** group - the flat
`project/<selectorName>.json`, byte-identical to a single-token clone. So a one-token user never sets
`GROUP` and sees no change, and a second token goes in its own group with no effect on the first (the one
exception is `make roles-check`: with `GROUP` unset it sweeps the default group AND every other group, see
[`roles.md`](roles.md#token-group-scope)):

```text
project/
  ethereum-testnet-sepolia.json        # default group (token #1)
  avalanche-fuji.json                   # default group (token #1)
  usdx/
    ethereum-testnet-sepolia.json       # group "usdx" (token #2)
    avalanche-fuji.json                 # group "usdx" (token #2)
```

The group name is validated `[a-z0-9][a-z0-9-]*` (dashes only, unlike chain names, which also allow
underscores; a bad name FAILs with a named error). Each group is its own **mesh universe**: the doctor's lane reciprocity reads siblings in the
same group directory, so a lane declared in one group never satisfies another's reciprocity, and a group's
git diff is confined to its directory. `make add-lane`, `remove-lane`, `adopt-token`, `snapshot-chain`,
`doctor`, and `roles-check` all take `GROUP=`. Those are the config-layer make targets; the **deploys**
have no make wrapper, so a second token's deploy is the first grouped step - a raw `forge script` that
takes `PROJECT_GROUP=<name>` directly (the same value `GROUP=` threads to the scripts):

```bash
# token #2 goes in group "usdx"; deploys pass PROJECT_GROUP directly (no make wrapper)
PROJECT_GROUP=usdx forge script script/deploy/DeployToken.s.sol ... --broadcast --verify
PROJECT_GROUP=usdx forge script script/deploy/DeployBurnMintTokenPool.s.sol ... --broadcast --verify
```

**Adding a second token, end to end.** The same steps a first token takes, all under one group, with
token #1 left untouched (omit `GROUP=`/`PROJECT_GROUP=` and you target the default group, i.e. token #1):

1. Deploy the token and pool under the group (the `forge script` above), or, for an already-deployed
   token, adopt it: `make adopt-token CHAIN=<chain> TOKEN=<addr> [TOKEN_POOL=<addr>] GROUP=usdx`. Either
   writes `project/usdx/<chain>.json`.
2. Declare its lanes: `make add-lane LOCAL=<chain> REMOTE=<remote> CAPACITY=<wei> RATE=<wei> BOTH=1 GROUP=usdx`.
3. Back up its authority: `make snapshot-chain CHAIN=<chain> GROUP=usdx`.
4. Verify: `make doctor CHAIN=<chain> GROUP=usdx` and `make roles-check CHAIN=<chain> GROUP=usdx`.

Repeat per chain the token spans. `make doctor` with no `GROUP=` also lists any groups that hold the chain,
so a routine check never silently skips a grouped token.

What stays **shared** across groups: `config/chains/*.json` (chain facts - one Router/selector per
physical chain) and the `history/` ledger. History is keyed by selectorName + token symbol + timestamp, so
co-located tokens in one group never collide; two **same-symbol** tokens in **different** groups still share
one `history/<category>/<selectorName>/` directory, their append-only entries separated only by timestamp
(harmless - `history/` is a write-only diary, never read back). Give each token its own group when more than
one token lives on a chain - it is the durable fix the doctor and the repoint warning point at.

**Canonical form (differs from `config/chains`).** Each store has its own on-disk canonical, and the writers
emit it directly so a no-op re-write is a zero-diff even on the direct `forge script` path (no `make`):

| Store                  | Canonical form                                                                                            | Emitted by                                                            |
| ---------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `project/*.json`       | sorted keys at every level, 2-space indent, **NO trailing newline** (forge `vm.writeJson`'s exact output) | the Solidity writers (`RegistryWriter`, `add-lane`, `snapshot-chain`) |
| `config/chains/*.json` | sorted keys, 2-space indent, **trailing newline** (`jq --indent 2 -S`)                                    | the sync + `jq` canonicalize step                                     |

`make fmt-config` repairs **both** stores to their respective canonical (`project/*.json` without the
trailing newline, `config/chains/*.json` with it). It is a **repair tool only**, never a required step - a
direct-forge run is already canonical. A golden test pins `project/` writer output against
`jq --indent 2 -S` (newline-normalized) so a future Foundry formatter change fails CI visibly.

### The `addresses{}` sub-store (the registry)

`addresses{}` is the deployed-address **registry**: the current-state, machine-read store that
`HelperConfig` resolution, the redeploy guard, and the doctor read back. (The word "registry" is reserved
for this subtree; the whole file is the "project store".) Its sole writers are the deploy recorder and
`make adopt-token`, both through `RegistryWriter`, which writes `.addresses` only. Values are **strings**:
EVM hex on EVM chains, base58 on non-EVM chains, family-validated on write against the chain's
`config/chains/<selectorName>.json` `.chainFamily`.

```jsonc
"addresses": {
  "active": {                       // <- what HelperConfig resolves (zero-export)
    "token":     "0xToken",         //    EVM hex here; a base58 string on a non-EVM chain
    "tokenPool": "0xPoolV2",        //    most-recently-deployed pool for the chain
    "lockBox":   "0xLockBox",
    "poolHooks": "0xHooks"
  },
  "deployments": {                  // <- uniquely named per artifact (type + version in the key)
    "BnM-T_Token":                   "0xToken",
    "BnM-T_BurnMintTokenPool_2.0.0": "0xPoolV2",   // key carries the pool type + version
    "BnM-T_LockBox":                 "0xLockBox",
    "BnM-T_BurnMint_PoolHooks":      "0xHooks"
  }
}
```

- **`active.<role>`** is the single slot `HelperConfig` resolves for each of the four roles
  (`token`/`tokenPool`/`lockBox`/`poolHooks`) - the zero-export default. `read(selectorName, role)` resolves
  `.addresses.active.<role>`. Environment variables still override the registry (see the
  [README](../README.md#project-store--projectselectornamejson-the-default) precedence ladder), as
  **read-only** inputs: an env-driven run resolves the override but never writes the store.
  > **`active` is what this repo last deployed - NOT proof of what is wired.** The on-chain
  > **TokenAdminRegistry** (`getPool(token)`) is the authority for the pool CCIP actually routes through.
  > They legitimately diverge whenever the wired pool was changed out-of-band (e.g. a `setPool` cut from a
  > Safe). `make doctor` reads the TAR and reports any divergence as a **WARN** (never a FAIL).
  > **Single-valued limit:** `active.<role>` holds exactly one address per role. Deploy two pools for the
  > same symbol on one chain and `active.tokenPool` points at the LAST one deployed; the zero-export getters
  > then resolve that same last pool for both tokens. To address a specific earlier artifact, pass it
  > explicitly via env or read its `deployments.<name>` entry. `make doctor` surfaces the ambiguity: when
  > `deployments{}` holds more than one token pool, the registry rung WARNs and names the
  > `{CHAIN}_TOKEN_POOL` targeted override.
- **`deployments.<name>`** is the uniquely-named archive: the key carries the pool's **type and version**, so
  distinct artifacts never collide or clobber each other in storage. This is a **storage** property, not a
  resolution one - the zero-export ladder resolves only `active`, which is single-valued (above).

Per-artifact keys and the redeploy guard are the reference of
[`deployed-addresses.md`](deployed-addresses.md); the resolution precedence is in the
[README](../README.md#project-store--projectselectornamejson-the-default).

### The `lanes{}` subtree - owner policy, not API fact

`lanes{}` declares **which remote chains this pool connects to and at what outbound rate limits** - the
mesh the owner intends, consumed by the `applyChainUpdates` flows: `ApplyChainUpdates` (CLI mode) applies
the declared `capacity`/`rate` (and the optional `inbound{}` block) whenever the rate-limit env vars are
unset, and the env vars remain the explicit override on top - an override that diverges from the
declaration is noticed on the console (with the exact `make add-lane` command to reconcile) and FAILs in
`make doctor` until the declaration is brought in line. That is policy, so it has a different
writer from everything above: the API sync never touches it (a `make sync` preserves it verbatim), and
`make add-lane LOCAL=<a> REMOTE=<b> CAPACITY=<wei> RATE=<wei> [BOTH=1]` is the scripted writer (`BOTH=1`
writes the reciprocal entry on the remote's file too). Each entry is keyed by the **remote's canonical
selectorName** and carries the remote's `chainSelector` plus the outbound rate-limit policy - all
quoted-decimal strings (the big-int rule above).

Beyond the required core (`remoteSelector`/`capacity`/`rate`), an entry may declare **optional policy
blocks**: `inbound{capacity,rate}` (written by `make add-lane ... INBOUND_CAPACITY=<wei>
INBOUND_RATE=<wei>`, or a hand edit) and the 2.0.0-only `v2{}` block - `v2.fastFinality.outbound` /
`v2.fastFinality.inbound` buckets, the per-lane `v2.feeConfig` fee override, and the per-lane
`v2.ccv` verifier requirements (all declared by a reviewed hand edit; `add-lane` has no flag surface
for them). The v2 blocks are consumed, not just verified: `UpdateRateLimiters` with `FAST_FINALITY=true`
on a 2.0.0 pool applies the declared `v2.fastFinality` bucket(s) whenever the rate-limit env vars are
unset for a direction, `UpdateTokenTransferFeeConfig` resolves every fee field the same way from
`v2.feeConfig` (env var > declared field > current on-chain value), and `UpdateCCVConfig` resolves
every CCV array the same way from `v2.ccv` - the same env-over-lanes ladder `ApplyChainUpdates` uses for
the core fields. The semantics are strict: an **absent** block or field is _undeclared_ - the doctor
does not reconcile it and the apply scripts fall through to their historical defaults; a **declared**
bucket with `0`/`0` is _declared-disabled_ and the doctor asserts the live bucket is off. `add-lane`
preserves every block verbatim when it rewrites the `lanes` subtree to append another lane.

**The `v2.ccv` block and the pool-scoped `ccvThreshold`.** CCVs (Cross-Chain Verifiers) live on the
pool's `AdvancedPoolHooks` contract (`TokenPool(pool).getAdvancedPoolHooks()`), so this policy needs a
2.0.0 pool **with hooks wired** - a declared `v2.ccv` on a cataloged pre-2.0.0 pool, or a 2.0.0 pool with
no hooks, FAILs in the doctor by name and refuses by name in `UpdateCCVConfig` (wire hooks first:
`updateAdvancedPoolHooks` / `DeployAdvancedPoolHooks`). `v2.ccv` carries four **optional** address-string
arrays, each declared-only-if-present (an absent array is _undeclared_ and is never reconciled; a present
empty array `[]` is _declared-empty_): `outboundCCVs` and `inboundCCVs` are the base verifier sets
required for every message in that direction, and `thresholdOutboundCCVs` / `thresholdInboundCCVs` are the
extra verifiers required only at or above the threshold amount. The on-chain rules are enforced by both
the setter and the hooks contract: a non-empty `threshold*CCVs` list **requires** a non-empty base list in
the same direction (`MustSpecifyUnderThresholdCCVsForThresholdCCVs`), no address may appear twice within a
list or be shared between a list and its threshold list, and a lane whose `outboundCCVs` **and**
`inboundCCVs` are both empty is **removed** from the pool's configured set. `applyCCVConfigUpdates` fully
**replaces** a lane's entry, so `UpdateCCVConfig` reads the current on-chain config first and writes back
every array the caller did not declare unchanged (declaring only `outboundCCVs` leaves the three other
arrays at their live values). The `ccvThreshold` is **pool-scoped and pool-global**, not per-lane: it is a
single value on the `AdvancedPoolHooks` (`setThresholdAmount`) that governs the threshold for every lane's
`threshold*CCVs`, declared at `poolPolicy.ccvThreshold` (see
[The `poolPolicy{}` block](#the-poolpolicy-block---pool-scoped-policy)); `0` or absent means no threshold
is declared.

Guards (each verified by `script/config/test-tooling.sh` and `test/config/LaneConfig.t.sol`):

- **Duplicate lane** → a logged no-op that leaves the file **byte-identical** (edit the JSON to change an
  existing lane's policy; `add-lane` never rewrites entries it did not create).
- **Self-lane** → refused: same `LOCAL`/`REMOTE` name, or two config files sharing one `chainSelector`
  (a pool must never register its own selector as a remote).
- **Placeholder pool** → a lane to a remote whose registry has no `tokenPool` yet logs a **WARN naming
  the missing deploy** - the lane can be declared ahead of the deploy, but transfers cannot execute over
  it until the pool exists.
- **Subtree isolation** → `add-lane` writes only `.lanes` (same preserve-and-replace pattern the sync
  uses for `.ccip`), so a lane edit can never disturb an API-served or hand-authored field.

`make doctor` closes the loop with two rungs. The **mesh rung** proves the committed policy agrees with
itself: every declared lane's remote config file must exist and its stored `remoteSelector` must equal
the remote's `chainSelector`, and reciprocity is checked across the whole mesh - a one-sided lane (A
declares B without B declaring A, in either direction) is a **FAIL naming both chains**. Non-EVM remotes
are exempt from reciprocity: they are destination-only in this repo and carry no `lanes{}` of their own
(see below). The **lanes rung** then proves the policy agrees with the **chain** (RPC-gated; see
[`config-architecture.md`](config-architecture.md)): every declared lane must be applied on the
registry-resolved pool, and every declared value (the core outbound bucket, and any declared
`inbound`/`v2`/`poolPolicy` block) must match the live chain. **A declared value the chain contradicts
is a FAIL naming the exact field** - the declaration is the intent, so a deliberate emergency throttle
is recorded by updating the declaration (the git diff documents the incident). The rung reports every
drifted field in one run and exits nonzero once at the end, so a multi-field drift is remediated as a
batch, not one fix-and-rerun at a time. Forward-intent states (a declared lane not yet applied), an
on-chain lane not declared back, an uncataloged pool version, and any unanswered read stay **WARN**:
they are pending work or degraded visibility, never proven drift.

### The `poolPolicy{}` block - pool-scoped policy

`poolPolicy{}` declares the pool-scoped (not per-lane) 2.0.0 policy values. It is optional and
hand-authored only: **its sole writer is a reviewed hand edit** - no script writes it, `add-lane` and
the sync preserve it verbatim, and no apply ever writes it back (`make fmt-config` repairs formatting).
Absent = undeclared: a project store without the block behaves byte-identically to today.

```jsonc
{
  "addresses": { ... },
  "lanes": { ... },
  "poolPolicy": {
    // OPTIONAL. The pool-global additional-CCV threshold on the AdvancedPoolHooks
    // (setThresholdAmount), quoted-decimal wei. Governs every lane's threshold*CCVs.
    "ccvThreshold": "1000000000000000000000",
    // OPTIONAL. The pool's allowed finality config (setAllowedFinalityConfig), declared in mode
    // terms. PRESENT (even empty {}) = declared; both keys optional:
    //   blockDepth   quoted-decimal 1..65535 - allow fast finality after N confirmations
    //   waitForSafe  bool - allow fast finality at the `safe` head
    //   both         - either mode acceptable;  {} - WAIT_FOR_FINALITY (fast finality disabled)
    "finality": { "blockDepth": "5", "waitForSafe": true }
  },
  "roles": { ... },
  "schema": 3
}
```

The declaration is in mode terms, never raw hex; the tooling derives the on-chain `bytes4` (lower 16
bits = block depth, bit 16 = the safe flag; full finality is always an allowed request - the value only
adds faster modes) and every doctor/console line prints the raw `bytes4` **plus** its decoded meaning
(e.g. `0x00010020 (WAIT_FOR_SAFE + BLOCK_DEPTH (32 blocks))`). Reserved flag bits this tooling cannot
decode print honestly as `Custom / Reserved flags`. Consumption mirrors the lanes ladder:
`UpdateCCVConfig` resolves the threshold as env (`CCV_THRESHOLD_AMOUNT`) > declared
`poolPolicy.ccvThreshold` > current on-chain, and `SetFinalityConfig` resolves the finality config as
env (`WAIT_FOR_SAFE`/`BLOCK_DEPTH`, either present) > declared `poolPolicy.finality` > the
WAIT_FOR_FINALITY reset. The doctor's lanes rung reconciles whatever is declared, once per chain: drift
FAILs naming the field; a declaration against a cataloged pre-2.0.0 pool, or `ccvThreshold` against a
2.0.0 pool with no hooks wired, FAILs by name (the declaration can never converge). Against an
**uncataloged** version the two values differ: `finality` is read best-effort (an unanswered
`getAllowedFinalityConfig` stays WARN; a successful read that contradicts the declaration still FAILs
as drift), while `ccvThreshold` emits the version WARN without attempting the hooks read. Both values
are pool-scoped **chain state, per chain**: each chain's project store declares its own pool's values.
A `ccvThreshold` key left at the top level of `config/chains/<name>.json` is a schema-rung **FAIL
naming the correct location and remediation** (pool policy never lives in the API-synced file).

### The `roles{}` subtree - declared authority, not API fact

`roles{}` declares **who holds every privileged role** across the token, its pool, the
TokenAdminRegistry, and (when present) the lockbox and hooks - the authority surface a security owner
intends. It is the durable, reviewed record of "who controls this deployment" (git-versioned once a fork
tracks `project/`), reconciled against the live chain by `make roles-check` and `make doctor`'s roles rung.
Its sole writer is **`make snapshot-chain CHAIN=<name>`** (backfill FROM chain, preserve-and-replace on the
`.roles` subtree only, the same discipline as `.addresses`/`.lanes`); the API sync never touches it, and
`roles-check` only reads
it. The full operational model - declared-intent vs live, the read-only-vs-writer split, the
drift-response decision tree, and the honest-coverage caveat - lives in [`docs/roles.md`](./roles.md);
this section is the field reference.

Every governance-critical single-holder slot (`token.defaultAdmin`, `token.ccipAdmin`, `pool.owner`,
`pool.rateLimitAdmin`, `pool.feeAdmin`, `tokenAdminRegistry.administrator`, `lockbox.owner`,
`hooks.owner`) is verified by a **direct getter point-read** - a plain `eth_call`, reliable on any RPC,
no `eth_getLogs`. Multi-holder role lists (`minters`, `burners`, `defaultAdmins`, `burnMintRoleAdmins`)
carry an honest **`complete` marker**: `true` only when the token enumerates its holders or a
`snapshot-chain SCAN_FROM_BLOCK=<n>` event scan proved the list; `false` (candidate seed) otherwise, and
the auditor WARNs so a partial list is never read as full.

The token block **dispatches on a declared `type`**, because the admin model differs per template - the
engine never assumes one:

| `type`       | Template                      | Top-level admin field(s)                       | Notes                                                                                                                                                                                                |
| ------------ | ----------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `crosschain` | `CrossChainToken`             | `defaultAdmin` (+ `pendingDefaultAdmin`)       | OZ `AccessControlDefaultAdminRules`; single-holder, two-step transfer. Has the separate `burnMintRoleAdmins` list (the `BURN_MINT_ADMIN_ROLE` that admins mint/burn - a slot a naive sweep forgets). |
| `burnmint`   | `BurnMintERC20`               | `defaultAdmins` (list)                         | plain OZ `AccessControl`; multi-holder `DEFAULT_ADMIN_ROLE` admins mint/burn directly.                                                                                                               |
| `factory`    | `FactoryBurnMintERC20`        | `owner`                                        | `Ownable`; enumerable `getMinters()`/`getBurners()` sets.                                                                                                                                            |
| `byo`        | unknown / externally deployed | whichever of `owner` / `defaultAdmins` answers | only the universal admin-registration points are probed; every other token-internal list stays `complete:false` (a clean check does NOT prove a BYO token's mint/burn rights are safe).              |

```jsonc
"roles": {
  // ── token authority (template-dispatched on `type`) ──────────────────────────
  "token": {
    "address": "0xa1f7882a...",             // the token this block describes (the snapshot/audit anchor;
                                             // make doctor WARNs when it diverges from addresses.active.token
                                             // - re-anchor after a repoint with make snapshot-chain)
    "type": "crosschain",                    // crosschain | burnmint | factory | byo — selects the admin model
    "ccipAdmin": "0xGov...",                 // getCCIPAdmin() — the TAR registration authority (one-step, owner-gated)
    "defaultAdmin": "0xGov...",              // crosschain only: defaultAdmin() (single-holder, two-step)
    "pendingDefaultAdmin": "0x0",            // crosschain only: a non-zero value means a transfer is IN FLIGHT
    // "owner": "0xGov...",                  // factory/byo instead of defaultAdmin
    // "defaultAdmins": { "holders": ["0x.."], "complete": false }, // burnmint/byo multi-holder admin list
    "burnMintRoleAdmins": {                  // crosschain only: BURN_MINT_ADMIN_ROLE holders (admin of mint/burn)
      "holders": ["0xGov..."], "complete": false
    },
    "minters": { "holders": ["0xPool..."], "complete": false }, // MINTER_ROLE holders (pool + any EOAs)
    "burners": { "holders": ["0xPool..."], "complete": false }  // BURNER_ROLE holders
  },

  // ── TokenAdminRegistry (the cutover authority; the TAR CONTRACT owner is out of scope) ──
  "tokenAdminRegistry": {
    "registry": "0x95F29FEE...",             // the TAR the token is REGISTERED in (may differ from the directory TAR)
    "administrator": "0xGov...",             // getTokenConfig(token).administrator — the onlyTokenAdmin authority
    "pendingAdministrator": "0x0"            // a non-zero value means a two-step admin transfer is IN FLIGHT
  },

  // ── pool authority (dual-generation: feeAdmin/hooks are 2.0.0-only) ──────────
  "pool": {
    "address": "0x4CAc9C8c...",              // the pool this block describes (the snapshot/audit anchor)
    "owner": "0xGov...",                     // Ownable2Step owner (config authority)
    "rateLimitAdmin": "0xSafe...",           // the fast-throttle authority (v2: inside getDynamicConfig)
    "feeAdmin": "0xGov...",                  // 2.0.0 only: inside getDynamicConfig
    "hooks": "0xHooks..."                    // 2.0.0 only: getAdvancedPoolHooks() (0x0 when unwired)
  },

  // ── OPTIONAL blocks: declared-only-if-present (omit for a burnmint chain with no lockbox/hooks) ──
  "lockbox": {                               // v2 LockRelease only (the v2 replacement for the v1 rebalancer)
    "address": "0xLockbox...", "owner": "0xGov...",
    "authorizedCallers": ["0xPool..."]       // enumerable → full two-sided set compare
  },
  "hooks": {                                 // the CCV/allowlist authority (security-critical)
    "address": "0xHooks...", "owner": "0xGov...", "policyEngine": "0xPolicy...",
    "allowlistEnabled": false,               // immutable (set at deploy)
    "allowlist": [], "authorizedCallers": ["0xPool..."]
  },
  // "rebalancer": "0xGov...",               // v1 LockRelease only (v2 uses the lockbox above)

  // ── OPTIONAL governance{} — three shapes: safe-only, timelock-only, or both. ──
  //    Absent = EOA-only chain (a valid SKIP, never a FAIL). ──────────────────
  "governance": {
    "safe": { "address": "0xSafe...", "threshold": 2, "owners": ["0x..","0x..","0x.."] },
    "timelock": {                            // pure declarations (proposers/etc.) are not enumerable on-chain
      "address": "0xTL...", "minDelay": 172800,
      "proposers": ["0xSafe..."], "cancellers": ["0xSafe..."], "executors": ["0x0"],
      "adminRenounced": true
    }
  }
}
```

Semantics the auditor enforces (all in `src/roles/RolesAuditor.sol`, mounted as the doctor's roles rung
and run standalone by `make roles-check`):

- **Type mismatch is a FAIL** - a declared `type` that contradicts the probed surface (e.g. `factory`
  declared for a token that answers `defaultAdmin()`) FAILs and the dependent token rungs are skipped
  to avoid cascade noise. `byo` never asserts a template; it only point-checks the universal admin
  points it declares.
- **Enumerable sets get a two-sided compare** (lockbox/hooks `authorizedCallers`, hooks `allowlist`,
  safe `owners`, factory-token minters/burners) - this detects BOTH a revoked holder AND a rogue
  additive grant. **Non-enumerable lists** (`crosschain`/`burnmint` mint/burn/admin) point-check each
  declared holder (revoke always detected) and **WARN that additive grants are unverified** - even when
  `complete:true`, because that completeness was proven at snapshot time, not now (never a silent CLEAN).
  Passing `SCAN_FROM_BLOCK=<n>` to `make roles-check` opts into an event-scan two-sided compare that
  turns an undeclared additive grant into a hard FAIL. A scanned list records `scannedFromBlock` next to
  `complete` as provenance (the block the completeness was proven from).
- **Absent optional block → SKIP, never FAIL** - `governance{}` on an EOA chain, `lockbox`/`hooks`/
  `rebalancer` where the pool has none. `governance{}` supports three shapes; a timelock-only shape
  with an EOA proposer is valid.
- **The TAR CONTRACT `owner`** (the registry-module authority) is the network operator's (Chainlink's),
  **deliberately out of scope** - never read, never a FAIL. `RegistryModuleOwnerCustom` has no
  privileged slot to declare (self-service registration).
- **Cross-consistency WARNs (never FAILs, they are conventions):** a declared safe that is not the
  pool's `rateLimitAdmin` (the fast-emergency-throttle convention); a timelock declared without the
  safe among its proposers.
- **Subtree isolation** - `snapshot-chain` writes only `.roles`, so a roles refresh never disturbs an
  API-served, `lanes{}`, or hand-authored field.

## Non-EVM (Solana) chain file

Non-EVM chains are supported as a **destination** only (to register a non-EVM pool as a remote on an EVM
source). `config/chains/solana-devnet.json` keeps the same shape but:

- `chainFamily` is `"svm"`, and `chainId` is the placeholder `"0"` - Solana has no EVM chain id. **The
  chainId identity guard cannot fire here**, so the `name` (selectorName) is the only validatable
  identity; the sync/doctor selectorName guard is what protects a non-EVM file from a wrong selector.
- The `ccip{}` block is **all-zero** and `feeTokens` is empty: non-EVM chains have no EVM-shaped
  `chainConfig`, so they are excluded from the API **address** sync (the sync SKIPs the `ccip{}`
  transform cleanly).
- The non-EVM chain's own **project store** carries **no `lanes{}`**: lanes are outbound policy, and
  non-EVM chains are destination-only here - an EVM chain may declare a lane **to** `solana-devnet` (exempt
  from the doctor's reciprocity rung), but `make add-lane LOCAL=solana-devnet ...` is refused (no lanes to
  write). Its `addresses{}` subtree DOES apply, holding the Solana token/pool as **base58 strings** (see
  below).
- **A non-EVM token/pool is stored as base58 and feeds `applyChainUpdates` from the store.** Adopt it with
  `make adopt-token CHAIN=<solana-chain> TOKEN_B58=<base58> [POOL_B58=<base58>]` (the `runNonEvm` path),
  which family-validates each value (base58 decodes to exactly 32 bytes) and writes
  `project/<solana-chain>.json` `addresses{}`. An EVM source then reads those remote bytes from the store
  through the selectorName-keyed getters when it lists Solana as a remote in `applyChainUpdates`, replacing
  the old env-only path. Two non-EVM chains that both report `chainId "0"` never collide, because the store
  is keyed by selectorName.
- **The base58 validation is syntactic only — sanity-check the accounts before wiring the lane.** `POOL_B58`
  must be the Solana pool's **config account** (the state PDA the OnRamp stamps as `sourcePoolAddress`), not
  the pool program id or the token mint; `TOKEN_B58` is the mint. Once the Solana side is deployed, stock
  CLIs confirm both (advisory — the accounts do not exist pre-deploy, so `AccountNotFound` is expected then):
  `solana account <POOL_B58> --url <cluster> --output json` must show the account exists, `executable:false`,
  and `owner` = the CCIP pool program id (a signer PDA returns `AccountNotFound`; a program id shows
  `executable:true`; a mint shows a token-program owner); `spl-token display <TOKEN_B58> --url <cluster>`
  must report an SPL/Token-2022 mint.
- **The chain-level identity + metadata ARE served for non-EVM and ARE synced.** `GET /v2/chains/{selector}`
  returns `chainMetadata{explorer,nativeCurrency}` for every family, so `displayName`, `chainFamily`,
  `environment`, `explorerUrl`, and `nativeCurrencySymbol` are sourced/refreshed from the API on Solana too
  (e.g. `explorerUrl` = `https://explorer.solana.com?cluster=devnet`, `nativeCurrencySymbol` = `SOL`). Only
  the EVM-shaped `ccip{}` addresses are skipped.

```jsonc
{
  "name": "solana-devnet", // canonical selectorName (already canonical; unchanged)
  "displayName": "Solana Devnet", // <- chain.displayName (API-synced)
  "chainNameIdentifier": "SOLANA_DEVNET", // hand
  "chainFamily": "svm", // <- chain.chainFamily (API-synced)
  "environment": "testnet", // <- chain.environment (API-synced)
  "chainId": "0", // placeholder - non-EVM; selectorName is the portable identity
  "chainSelector": "16423721717087811551",
  "rpcEnv": "SOLANA_DEVNET_RPC_URL", // hand
  "ccip": {
    "router": "0x00...00",
    "rmnProxy": "0x00...00",
    "tokenAdminRegistry": "0x00...00",
    "registryModuleOwnerCustom": "0x00...00",
    "feeQuoter": "0x00...00",
    "tokenPoolFactory": "0x00...00",
    "link": "0x00...00",
    "feeTokens": []
  },
  "explorerUrl": "https://explorer.solana.com?cluster=devnet", // <- chainMetadata.explorer.url (API-synced)
  "nativeCurrencySymbol": "SOL" // <- chainMetadata.nativeCurrency.symbol (API-synced)
}
```

The Solana deployed addresses live in `project/solana-devnet.json` `addresses{}` as base58 strings, not in
this file.

## Related

- [`deployed-addresses.md`](deployed-addresses.md) - the deployed-address loop (writers, overrides,
  reconcile, warns), the per-artifact keying table, the redeploy guard, and the template-vs-fork tracking
  rule.
- [`roles.md`](roles.md) - the `roles{}` operational runbook.
- [`config-architecture.md`](config-architecture.md) - the `make`-command reference and the layered store
  diagrams.
