---
type: reference
---

# The CCIP REST API v2 spec

Source of truth for every script under `script/config/` that talks to the API. Read it before adding
or changing a call; do not guess parameter names.

- Swagger UI: <https://api.ccip.chain.link/docs>
- Machine-readable spec: <https://api.ccip.chain.link/docs/swagger-ui-init.js> (OpenAPI document
  inlined under the `swaggerDoc` key; `curl` it and slice that value out)

Base URL is `https://api.ccip.chain.link/v2`, overridable with the non-secret `CCIP_API_BASE`
(see `.env.example`). Every call this repo makes is read-only and unauthenticated.

## A defaulted filter is a silent wrong answer

The hazard these scripts keep hitting: an omitted parameter is not neutral. The API applies its own
default, answers HTTP 200 with a well-formed body and a confident `totalCount`, and the operator sees
"nothing found" instead of an error.

Two instances, both real:

- `GET /tokens` has **`reviewedOnly`, defaulting to `true`** - only tokens whose projects Chainlink
  Labs has reviewed. `?environment=testnet` returns 22 tokens; adding `&reviewedOnly=false` returns
  ~25,900. Filtered by `admin=`, the default returns `totalCount 0` for an operator who has 169
  tokens. `script/config/discover-tokens.sh` therefore always sends `reviewedOnly=false`.
- `GET /chains` was queried as `?environment=testnet`, hiding every mainnet chain. Unset returns both
  planes, which is what `script/config/sync-discover.sh` now does.

So: check the spec's `default` for every parameter you omit, and prefer sending the value explicitly
over relying on the default. `GET /tokens` has one more defaulted boolean, `expand` (default `false`),
which decides whether each `remoteChains[]` entry carries `status` and `remoteTokenAddress` at all.

Name enumeration is cheap but not sufficient: an unknown parameter gives
`400 {"error":"BAD_REQUEST","message":"Unknown query parameter 'zzz'"}`, which finds typos but never
finds a parameter you did not think to try. That is how `reviewedOnly` was missed. Read the spec.

## Routes this repo calls

| Route | Caller | Query parameters |
| --- | --- | --- |
| `GET /chains` | [`sync-discover.sh`](../../script/config/sync-discover.sh) | `environment` only (unset = both planes). No paging. |
| `GET /chains/{selector}` | [`ccip-config-source.sh`](../../script/config/ccip-config-source.sh), [`ccip-chain-meta.sh`](../../script/config/ccip-chain-meta.sh) | none accepted. |
| `GET /tokens` | [`discover-tokens.sh`](../../script/config/discover-tokens.sh) | `chainSelector`, `remoteChainSelector`, `groupId`, `symbol`, `address`, `admin`, `environment`, `reviewedOnly`, `expand`, `limit`, `cursor`. |
| `GET /tokens/{chainSelector}/{tokenAddress}` | [`discover-tokens.sh`](../../script/config/discover-tokens.sh) with `POOL=1` | none accepted. |

Only the token detail route describes the pool. It carries the type three ways: `pool.typeAndVersion`
is the contract's own string (`"SiloedLockReleaseTokenPool 1.6.0"`), `pool.type` an API enum
(`SILOED_LOCK_RELEASE`, `BURN_MINT`, ...) and `pool.version` a version number that is `null` for a dev
build. It also reports `pool.finality` (`{mode, blockDepth, safe}`), the pool-scoped allowed-finality
config. Both are a read of the chain at indexing time, so they lag a config change and are evidence for
a cross-check, never the authority a write path acts on - `PoolVersion._resolve` reads the pool itself.
The list route carries no pool fields even with `expand=true`, and a group's `members` carry only
`address`, `chainSelector` and `symbol`.

`GET /tokens` pages by **keyset, not offset**: `page` and `offset` are rejected with a 400. Follow
`pagination.cursor` while `pagination.hasNextPage` is true. Filters may travel with the cursor only if
they match the ones encoded in it; a differing filter is a 400.
