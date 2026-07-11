# Chain config schema (`config/chains/<selectorName>.json`)

This repo treats **CCIP chain metadata as DATA, not code**. Every chain selector, router, and CCIP
infra address the scripts need is read from `config/chains/<selectorName>.json` at build/test time via
`vm.parseJson*` (`src/config/ChainConfig.sol`). There are **no hardcoded selectors or CCIP addresses**
in Solidity: `HelperConfig` discovers the chain list by scanning the directory (`vm.readDir`), so adding
a chain - or updating a CCIP address - is a reviewed config edit with zero Solidity changes.

The operational how-to (discover → add-chain → sync → doctor, and the "which command when" table) lives
in the [README](../README.md#configuration); the `make`-command reference and the layered architecture
(with diagrams) are in **[`config-architecture.md`](config-architecture.md)**. This document is the
**field-by-field reference**.

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

The **git-tracked** `config/chains/<selectorName>.json` is a durable, versioned store; each part has a single
writer so a git diff is an unambiguous audit log. (The `addresses/<chainId>.json` row below is a **separate,
gitignored** file — its single-writer integrity comes from the deploy-time recorder, not from git history;
see [its section](#the-deployed-address-registry---addresseschainidjson-schema-v2).)

| Subtree / field group                            | Owner                | Sole writer                                                   |
| ------------------------------------------------ | -------------------- | ------------------------------------------------------------ |
| `ccip{}` + the API-served identity/metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`) | the CCIP REST API | the **API sync** (`make add-chain` / `sync` / `sync-all`) - never by hand |
| `lanes{}` (which remotes this pool connects to, at what outbound rate limits) | the token owner (policy) | **`make add-lane`** / **`make remove-lane`** or a reviewed hand edit - **never the API sync** |
| hand-authored keys the API serves nothing for (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`) | repo maintainers | a **reviewed hand edit** in a pull request |
| immutable join keys (`name`, `chainSelector`, `chainId`) | the chain-selectors registry | seeded at `add-chain`, then **guard-validated** by the sync (never rewritten) |
| `addresses/<chainId>.json` (separate, **gitignored**) | the deployer         | the **deploy scripts** — one `DeploymentRecorder` call → ledger + `RegistryWriter`, on `--broadcast` |

The sync enforces this structurally: `SyncCcipConfig.run` writes **only** the API-served fields — the
`.ccip` subtree (`vm.writeJson(json, path, ".ccip")`) plus the five identity/metadata keys the CCIP REST
API serves (each a targeted `vm.writeJson(value, path, ".<key>")`) — so every hand-authored key
(`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`) and the `lanes{}` subtree are preserved
untouched, and the join keys are validated, not overwritten. `make add-lane` mirrors the same discipline
from the other side: it writes **only** the `.lanes` subtree (`vm.writeJson(lanes, path, ".lanes")`) and
never touches an API-served field. **The rule of thumb: if a field exists on `GET /v2/chains/{selector}`,
the sync sources it from the API; you never hand-type it. If a field is policy — which remotes, at what
rate limits — the owner writes it, and the sync never will.** The general config-as-data model also has a
**roles** subtree (the privileged-role surface, governance-written); that one is **not present in this
repo yet** - but the one-writer principle is the same.

## EVM chain file - every field

Example (`config/chains/ethereum-testnet-sepolia.json`), grouped by writer:

```jsonc
{
  // ── join keys (seeded at add-chain, then guard-validated by the sync; never rewritten) ───
  "name": "ethereum-testnet-sepolia",      // canonical CCIP selectorName; == file basename; the CHAIN= arg
  "chainId": "11155111",                   // native chain id, quoted STRING (see big-int note); "0" for non-EVM
  "chainSelector": "16015286601757825753", // uint64 CCIP selector, quoted STRING; the primary join key

  // ── API-synced identity + metadata (sourced from GET /v2/chains/{selector}; never hand-edit) ──
  "displayName": "Ethereum Sepolia",       // <- chain.displayName; human label for logs / output links
  "chainFamily": "evm",                    // <- chain.chainFamily (lowercased); dispatches EVM vs non-EVM
  "environment": "testnet",                // <- chain.environment ("testnet" | "mainnet")
  "explorerUrl": "https://sepolia.etherscan.io", // <- chainMetadata.explorer.url; output/verification links
  "nativeCurrencySymbol": "ETH",           // <- chainMetadata.nativeCurrency.symbol; native gas-token symbol

  // ── ccip{} : API-synced (overwritten by the sync; never hand-edit) ───────────
  "ccip": {
    "router": "0x0BF3dE8c...",               // CCIP Router - entrypoint for ccipSend / offRamp
    "rmnProxy": "0xba3f6251...",             // RMN (Risk Management Network) proxy / ARMProxy
    "tokenAdminRegistry": "0x95F29FEE...",   // TokenAdminRegistry - maps token → its pool + admin
    "registryModuleOwnerCustom": "0xa3c796d4...", // RegistryModuleOwnerCustom - claim-admin registry module
    "feeQuoter": "0x8632C302...",            // FeeQuoter - quotes CCIP fees (reference)
    "tokenPoolFactory": "0x2067C044...",     // TokenPoolFactory - deploys standard pools (reference)
    "link": "0x779877A7...",                 // LINK token (the LINK fee token on this chain)
    "feeTokens": ["0xc4bF5CbD...", "0x779877A7...", "0x097D90c9..."] // accepted CCIP fee tokens (reference)
  },

  // ── lanes{} : owner POLICY (written by make add-lane; NEVER touched by the API sync).
  //    Ships empty ({}) - the entry below shows the shape one `make add-lane` produces ───────
  "lanes": {
    "ethereum-testnet-sepolia-mantle-1": { // keyed by the REMOTE chain's selectorName
      "remoteSelector": "8236463271206331221",  // the remote's chainSelector (doctor-verified)
      "capacity": "100000000000000000000000",   // outbound rate-limit bucket capacity, wei (quoted string)
      "rate": "100000000000000000000",          // outbound rate-limit refill rate, wei/second (quoted string)
      // ── optional blocks. ABSENT means undeclared (the doctor does not reconcile them);
      //    a declared block with 0/0 means declared-DISABLED (the doctor asserts the bucket is off)
      "inbound": {                              // inbound rate-limit policy (add-lane INBOUND_* args)
        "capacity": "100000000000000000000000",
        "rate": "100000000000000000000"
      },
      "v2": {                                   // 2.0.0-only lane surface (declared by hand edit)
        "fastFinality": {                       // fast-finality (FTF) buckets, each direction optional
          "outbound": { "capacity": "50000000000000000000000", "rate": "50000000000000000000" },
          "inbound": { "capacity": "50000000000000000000000", "rate": "50000000000000000000" }
        },
        "feeConfig": {                          // per-lane token transfer fee override; each field optional
          "destGasOverhead": "90000",           //   dest-chain execution gas overhead
          "destBytesOverhead": "32",            //   data-availability bytes overhead
          "finalityFeeUSDCents": "0",           //   default-finality fee, 0.01-USD units
          "fastFinalityFeeUSDCents": "0",       //   fast-finality fee, 0.01-USD units
          "finalityTransferFeeBps": "10",       //   default-finality bps fee [0-9999]
          "fastFinalityTransferFeeBps": "25"    //   fast-finality bps fee [0-9999]
        },
        "ccv": {                                // per-lane CCV (Cross-Chain Verifier) requirements; each array optional
          "outboundCCVs": ["0xCCV1..."],        //   base CCVs required for OUTBOUND messages to this remote
          "thresholdOutboundCCVs": ["0xCCV2..."], //   extra outbound CCVs required at/above ccvThreshold (needs outboundCCVs)
          "inboundCCVs": ["0xCCV1..."],         //   base CCVs required for INBOUND messages from this remote
          "thresholdInboundCCVs": ["0xCCV2..."]   //   extra inbound CCVs required at/above ccvThreshold (needs inboundCCVs)
        }
      }
    }
  },

  // ── chain-level CCV threshold : owner POLICY, pool-GLOBAL (declared by hand edit; sibling of lanes/ccip) ──
  //    the additional-CCV threshold amount (wei, quoted decimal string). 0 / absent = no threshold declared.
  //    NOT per-lane: one value on the pool's AdvancedPoolHooks governs every lane's threshold*CCVs arrays.
  "ccvThreshold": "1000000000000000000000",

  // ── hand-authored (the API serves nothing for these; reviewed in a PR, preserved by sync) ──
  "chainNameIdentifier": "ETHEREUM_SEPOLIA", // UPPER_SNAKE env-var prefix: <ID>_RPC_URL, <ID>_TOKEN, <ID>_TOKEN_POOL
  "rpcEnv": "ETHEREUM_SEPOLIA_RPC_URL",    // name of the env var holding this chain's RPC URL
  "confirmations": 2,                      // block confirmations the scripts wait for (operator choice)
  "ccipBnM": "0x9a97F119..."               // optional CCIP-BnM test token (0x0 / omitted when unused)
}
```

### Field reference

"Written by" values: **API sync** = sourced + refreshed + drift-checked from the CCIP REST API;
**API sync (guard)** = seeded at `add-chain` then validated (not rewritten) every sync; **hand** = the
API serves nothing for it, so a reviewed PR owns it and the sync preserves it verbatim.

| Field                        | Type / format                    | Written by            | API source (if any)                            | Consumed by                                    |
| ---------------------------- | -------------------------------- | --------------------- | ---------------------------------------------- | ---------------------------------------------- |
| `name`                       | string (canonical selectorName)  | **API sync (guard)**  | `chain.name`                                   | file key + basename; validated by the sync     |
| `chainId`                    | quoted decimal string (`"0"` non-EVM) | **API sync (guard)** | `chain.chainId` (EVM; `"0"` placeholder non-EVM) | `ChainConfig.chainId`; sync identity guard  |
| `chainSelector`              | quoted `uint64` string           | **API sync (guard)**  | `chain.chainSelector`                          | `ChainConfig.load`; the primary join key       |
| `displayName`                | string                           | **API sync**          | `chain.displayName`                            | `ChainConfig.load` → `chainName`; log output   |
| `chainFamily`                | `"evm"` \| `"svm"`               | **API sync**          | `chain.chainFamily` (lowercased)               | `ChainConfig.load`; EVM/non-EVM dispatch       |
| `environment`                | `"testnet"` \| `"mainnet"`       | **API sync**          | `chain.environment`                            | provenance                                     |
| `explorerUrl`                | URL string                       | **API sync**          | `chainMetadata.explorer.url`                   | `ChainConfig.load`; output/verification links  |
| `nativeCurrencySymbol`       | string                           | **API sync**          | `chainMetadata.nativeCurrency.symbol`          | `ChainConfig.load`                             |
| `ccip.router`                | address                          | **API sync**          | `chainConfig.router` (active)                  | `ChainConfig.load` → `router`                  |
| `ccip.rmnProxy`              | address                          | **API sync**          | `chainConfig.rmn` (active)                     | `ChainConfig.load` → `rmnProxy`                |
| `ccip.tokenAdminRegistry`    | address                          | **API sync**          | `chainConfig.tokenAdminRegistry` (active)      | `ChainConfig.load`                             |
| `ccip.registryModuleOwnerCustom` | address                      | **API sync**          | `chainConfig.registryModule` (active)          | `ChainConfig.load`                             |
| `ccip.feeQuoter`             | address                          | **API sync**          | `chainConfig.feeQuoter` (active)               | reference (drift-checked)                      |
| `ccip.tokenPoolFactory`      | address                          | **API sync**          | `chainConfig.tokenPoolFactory` (active)        | reference (drift-checked)                      |
| `ccip.link`                  | address                          | **API sync**          | `chainConfig.feeTokens[symbol==LINK]`          | `ChainConfig.load` → `link`                    |
| `ccip.feeTokens`             | address[]                        | **API sync**          | `chainConfig.feeTokens[].tokenAddress`         | reference (drift-checked)                      |
| `lanes.<remote>`             | object, keyed by the remote's selectorName | **owner policy** (`make add-lane`) | — (policy, not an API fact)  | lane wiring; the doctor's mesh rung            |
| `lanes.<remote>.remoteSelector` | quoted `uint64` string        | **owner policy** (`make add-lane`) | — (copied from the remote's config)   | doctor: must equal the remote's `chainSelector` |
| `lanes.<remote>.capacity`    | quoted decimal string (wei)      | **owner policy** (`make add-lane`) | —                                      | outbound rate-limit bucket capacity            |
| `lanes.<remote>.rate`        | quoted decimal string (wei/s)    | **owner policy** (`make add-lane`) | —                                      | outbound rate-limit refill rate                |
| `lanes.<remote>.inbound`     | object `{capacity, rate}` (optional) | **owner policy** (`make add-lane INBOUND_*`) | —                        | inbound rate-limit policy; doctor lanes rung   |
| `lanes.<remote>.v2`          | object (optional, 2.0.0 pools)   | **owner policy** (hand edit)       | —                                      | fast-finality buckets (`UpdateRateLimiters` FAST_FINALITY mode) + fee config (`UpdateTokenTransferFeeConfig`) + CCV config (`UpdateCCVConfig`); doctor lanes rung |
| `lanes.<remote>.v2.ccv`      | object (optional, 2.0.0 pools w/ hooks) | **owner policy** (hand edit) | —                             | per-lane CCV requirements (`UpdateCCVConfig`); doctor lanes rung. Four optional address-string arrays below |
| `lanes.<remote>.v2.ccv.outboundCCVs` | address[] string (optional) | **owner policy** (hand edit) | —                               | base CCVs required for outbound messages to the remote (`AdvancedPoolHooks.applyCCVConfigUpdates`) |
| `lanes.<remote>.v2.ccv.thresholdOutboundCCVs` | address[] string (optional) | **owner policy** (hand edit) | —                    | extra outbound CCVs required at/above `ccvThreshold`; requires a non-empty `outboundCCVs` |
| `lanes.<remote>.v2.ccv.inboundCCVs` | address[] string (optional) | **owner policy** (hand edit) | —                                | base CCVs required for inbound messages from the remote |
| `lanes.<remote>.v2.ccv.thresholdInboundCCVs` | address[] string (optional) | **owner policy** (hand edit) | —                     | extra inbound CCVs required at/above `ccvThreshold`; requires a non-empty `inboundCCVs` |
| `ccvThreshold`               | quoted decimal string (wei), chain-level | **owner policy** (hand edit) | —                          | pool-GLOBAL additional-CCV threshold (`AdvancedPoolHooks.setThresholdAmount`); 0/absent = undeclared; doctor lanes rung |
| `chainNameIdentifier`        | UPPER_SNAKE string               | hand                  | — (not in the API)                             | `ChainConfig.load`; the `<ID>_*` env prefix    |
| `rpcEnv`                     | env-var name string              | hand                  | — (not in the API)                             | fork setup; the doctor's RPC rung              |
| `confirmations`              | number                           | hand                  | — (`chainConfig.finality`/`blockTime` are `null`) | `ChainConfig.load`                          |
| `ccipBnM`                    | address (`0x0` / omitted = none) | hand                  | — (no authoritative CCIP token API)            | `ChainConfig.load`                             |

> **`chainNameIdentifier`/`rpcEnv` are DERIVED for newly added chains.** `make add-chain` seeds
> `chainNameIdentifier` as UPPER_SNAKE of the selectorName (e.g. `avalanche-testnet-fuji` →
> `AVALANCHE_TESTNET_FUJI`) and `rpcEnv` as `<chainNameIdentifier>_RPC_URL`, so a fresh chain's names
> may differ in style from the six bundled chains' hand-curated SHORT forms (`ETHEREUM_SEPOLIA`, not
> `ETHEREUM_TESTNET_SEPOLIA`). You cannot always guess them — so `add-chain` **prints the exact
> `chainNameIdentifier` and `rpcEnv` it generated** in its next-steps output. Override at generation
> time with the `CHAIN_NAME_IDENTIFIER` / `RPC_ENV` env vars; these keys are hand-authored thereafter
> (the sync never rewrites them).

> **Big integers are quoted STRINGS.** `chainSelector` (uint64) and `chainId` exceed JSON's safe integer
> range (2^53), so they are stored as quoted decimals and read with `vm.parseJsonUint`, which parses
> quoted decimals. Never store them as bare JSON numbers - precision is silently lost.

> **Targeted key reads, not whole-struct decode.** `ChainConfig` reads by path (`.ccip.router`,
> `.chainSelector`, …), so it is order-independent and robust to the alphabetical key reordering that
> `vm.writeJson` and the canonical `jq --indent 2 -S` format perform.

### The `lanes{}` subtree - owner policy, not API fact

`lanes{}` declares **which remote chains this pool connects to and at what outbound rate limits** - the
mesh the owner intends, consumed by the `applyChainUpdates` flows: `ApplyChainUpdates` (CLI mode) applies
the declared `capacity`/`rate` (and the optional `inbound{}` block) whenever the rate-limit env vars are
unset, and the env vars remain the explicit override on top - an override that diverges from the
declaration is noticed on the console (with the exact `make add-lane` command to reconcile) and WARNs in
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
the core fields. The semantics are strict: an **absent** block or field is *undeclared* - the doctor
does not reconcile it and the apply scripts fall through to their historical defaults; a **declared**
bucket with `0`/`0` is *declared-disabled* and the doctor asserts the live bucket is off. `add-lane`
preserves every block verbatim when it rewrites the `lanes` subtree to append another lane.

**The `v2.ccv` block and the chain-level `ccvThreshold`.** CCVs (Cross-Chain Verifiers) live on the
pool's `AdvancedPoolHooks` contract (`TokenPool(pool).getAdvancedPoolHooks()`), so this policy needs a
2.0.0 pool **with hooks wired** - a declared `v2.ccv` on a pre-2.0.0 pool, or a 2.0.0 pool with no
hooks, WARNs in the doctor and refuses by name in `UpdateCCVConfig` (wire hooks first:
`updateAdvancedPoolHooks` / `DeployAdvancedPoolHooks`). `v2.ccv` carries four **optional** address-string
arrays, each declared-only-if-present (an absent array is *undeclared* and is never reconciled; a present
empty array `[]` is *declared-empty*): `outboundCCVs` and `inboundCCVs` are the base verifier sets
required for every message in that direction, and `thresholdOutboundCCVs` / `thresholdInboundCCVs` are the
extra verifiers required only at or above the threshold amount. The on-chain rules are enforced by both
the setter and the hooks contract: a non-empty `threshold*CCVs` list **requires** a non-empty base list in
the same direction (`MustSpecifyUnderThresholdCCVsForThresholdCCVs`), no address may appear twice within a
list or be shared between a list and its threshold list, and a lane whose `outboundCCVs` **and**
`inboundCCVs` are both empty is **removed** from the pool's configured set. `applyCCVConfigUpdates` fully
**replaces** a lane's entry, so `UpdateCCVConfig` reads the current on-chain config first and writes back
every array the caller did not declare unchanged (declaring only `outboundCCVs` leaves the three other
arrays at their live values). The `ccvThreshold` is **chain-level and pool-global**, not per-lane: it is a
single value on the `AdvancedPoolHooks` (`setThresholdAmount`) that governs the threshold for every lane's
`threshold*CCVs`; `0` or absent means no threshold is declared.

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
registry-resolved pool with live rate limits (and any declared `inbound`/`v2` blocks) matching the
declared values, and every on-chain supported selector must be declared back - all WARN-only, since
live drift can be a deliberate emergency throttle.

## Non-EVM (Solana) chain file

Non-EVM chains are supported as a **destination** only (to register a non-EVM pool as a remote on an EVM
source). `config/chains/solana-devnet.json` keeps the same shape but:

- `chainFamily` is `"svm"`, and `chainId` is the placeholder `"0"` - Solana has no EVM chain id. **The
  chainId identity guard cannot fire here**, so the `name` (selectorName) is the only validatable
  identity; the sync/doctor selectorName guard is what protects a non-EVM file from a wrong selector.
- The `ccip{}` block is **all-zero** and `feeTokens` is empty: non-EVM chains have no EVM-shaped
  `chainConfig`, so they are excluded from the API **address** sync (the sync SKIPs the `ccip{}`
  transform cleanly, and `ccipBnM` stays `0x0`).
- There is **no `lanes{}`**: lanes are outbound policy, and non-EVM chains are destination-only here -
  an EVM chain may declare a lane **to** `solana-devnet` (exempt from the doctor's reciprocity rung),
  but `make add-lane LOCAL=solana-devnet ...` is refused (no lanes object to write into).
- **The chain-level identity + metadata ARE served for non-EVM and ARE synced.** `GET /v2/chains/{selector}`
  returns `chainMetadata{explorer,nativeCurrency}` for every family, so `displayName`, `chainFamily`,
  `environment`, `explorerUrl`, and `nativeCurrencySymbol` are sourced/refreshed from the API on Solana too
  (e.g. `explorerUrl` = `https://explorer.solana.com?cluster=devnet`, `nativeCurrencySymbol` = `SOL`). Only
  the EVM-shaped `ccip{}` addresses are skipped.

```jsonc
{
  "name": "solana-devnet",                 // canonical selectorName (already canonical; unchanged)
  "displayName": "Solana Devnet",          // <- chain.displayName (API-synced)
  "chainNameIdentifier": "SOLANA_DEVNET",  // hand
  "chainFamily": "svm",                    // <- chain.chainFamily (API-synced)
  "environment": "testnet",                // <- chain.environment (API-synced)
  "chainId": "0",                          // placeholder - non-EVM; selectorName is the portable identity
  "chainSelector": "16423721717087811551",
  "rpcEnv": "SOLANA_DEVNET_RPC_URL",       // hand
  "ccip": { "router": "0x00...00", "rmnProxy": "0x00...00", "tokenAdminRegistry": "0x00...00",
            "registryModuleOwnerCustom": "0x00...00", "feeQuoter": "0x00...00",
            "tokenPoolFactory": "0x00...00", "link": "0x00...00", "feeTokens": [] },
  "confirmations": 0,                      // hand (operator choice)
  "explorerUrl": "https://explorer.solana.com?cluster=devnet", // <- chainMetadata.explorer.url (API-synced)
  "nativeCurrencySymbol": "SOL",           // <- chainMetadata.nativeCurrency.symbol (API-synced)
  "ccipBnM": "0x00...00"                    // hand (optional)
}
```

## The deployed-address registry - `addresses/<chainId>.json` (schema v2)

A complementary, separate store, keyed by numeric `chainId` (not selectorName), user-specific and
**gitignored** (only the committed `addresses/11155111.example.json` shows the shape). Unlike the git-tracked
`config/chains/*.json` above, a per-chain registry file is **local to the machine that ran the deploy** - a
fresh clone or a CI job has none. It is governed by the deploy scripts alone; the API sync never touches it.

### Two sub-stores: `active` role pointers + named `deployments`

```jsonc
{
  "active": {                       // <- what HelperConfig resolves (zero-export)
    "token":     "0xToken",
    "tokenPool": "0xPoolV2",        // most-recently-deployed pool for the chain
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
  (`token`/`tokenPool`/`lockBox`/`poolHooks`) - the zero-export default. `read(chainId, role)` resolves
  `.active.<role>`, with a legacy fallback to a flat pre-v2 top-level `.<role>` so any older local file keeps
  working. Environment variables still override the registry (see the [README](../README.md#deployed-address-registry--addresseschainidjson-the-default) precedence ladder).
  > **`active` is what this repo last deployed - NOT proof of what is wired.** The on-chain
  > **TokenAdminRegistry** (`getPool(token)`) is the authority for the pool CCIP actually routes through.
  > They legitimately diverge whenever the wired pool was changed out-of-band (e.g. a `setPool` cut from a
  > Safe). `make doctor` reads the TAR and reports any divergence as a **WARN** (never a FAIL).
  > **Single-valued limit:** `active.<role>` holds exactly one address per role. Deploy two pools for the
  > same symbol on one chain and `active.tokenPool` points at the LAST one deployed; the zero-export getters
  > (`getDeployedTokenPool`/`LockBox`/`PoolHooks` read only `active`) then resolve that same last pool for
  > both tokens. To address a specific earlier artifact, pass it explicitly via env or read its
  > `deployments.<name>` entry.
- **`deployments.<name>`** is the uniquely-named archive: the key carries the pool's **type and version**, so
  distinct artifacts never collide or clobber each other in storage. Note this is a **storage** property, not
  a resolution one - the zero-export ladder resolves only `active`, which is single-valued (above).

### Per-artifact keying

| Artifact    | `deployments` key                         | `active` role | Why |
| ----------- | ----------------------------------------- | ------------- | --- |
| `token`     | `{symbol}_Token`                          | `token`       | one token per symbol |
| `tokenPool` | `{symbol}_{poolType}TokenPool_{version}`  | `tokenPool`   | type + version in the key so artifacts never collide |
| `lockBox`   | `{symbol}_LockBox`                        | `lockBox`     | one lockbox per lock-release token |
| `poolHooks` | `{symbol}_{poolType}_PoolHooks`           | `poolHooks`   | hooks belong to a pool, not a chain |

### One writer per artifact (the recorder)

Each deploy script makes **one** call to `script/utils/DeploymentRecorder.s.sol` per artifact. That single
call (a) emits the detailed timestamped ledger file via `DeploymentUtils.save*` (format unchanged) **and**
(b) upserts `deployments[name]` + `active[role]` via `RegistryWriter` - the two stores can no longer drift,
because one writer owns both. The redeploy guard keys on the unique `deployments` name: re-deploying the
*same* name is refused unless `FORCE_REDEPLOY=true` (which drops the stale entry and clears its `active`
pointer, then records the replacement), while a new *version* deploys freely. The registry is the **only**
address store read back (by `HelperConfig` resolution and the guard); the `script/deployments/**` ledger is
write-only history. Resolution precedence and the guard are documented in the
[README](../README.md#deployed-address-registry--addresseschainidjson-the-default).
