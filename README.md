# CCIP Cross-Chain Token toolkit

> **NOTE:** This repository represents an educational example to use a Chainlink system, product, or service and is provided to demonstrate how to interact with Chainlink’s systems, products, and services to integrate them into your own. This template is provided “AS IS” and “AS AVAILABLE” without warranties of any kind, it has not been audited, and it may be missing key checks or error handling to make the usage of the system, product or service more clear. Do not use the code in this example in a production environment without completing your own audits and application of best practices. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outputs that are generated due to errors in code.

A Foundry toolkit for deploying, registering, wiring, and governing Chainlink CCIP cross-chain tokens
(CCT). It ships composable, idempotent primitives (forge scripts) and a `make` golden path over them.
Chains are data (`config/chains/*.json`, synced from the CCIP API), deploy state is a project store (git-tracked once a fork un-gitignores it), and history is an append-only local ledger.

AI agents: start at [AGENTS.md](AGENTS.md). Humans: pick a path below.

## Choose your path

- **New here?** Follow the [Quick start](#quick-start) to deploy a token and a pool on a testnet and send
  a transfer.
- **Running in production?** Go to [Production operations](#production-operations) for execution modes,
  the roles handoff, mesh expansion, and the pre-mainnet checklist.
- **Looking for one command?** The [primitives catalog](docs/primitives/index.md) has one page per script,
  and `make help` lists every make target.
- **Forking this to run your own tokens?** Un-gitignore `project/` so your lanes, roles, and deployed
  addresses become your team's tracked source of truth (public addresses only, never secrets), then keep it
  reconciled with `make doctor` / `make roles-check`. See the
  [Tracking rule](docs/deployed-addresses.md#tracking-rule-template-vs-fork).

## Prerequisites

The core layer below is enough to deploy, wire, and configure. Two more layers (sending and monitoring
transfers, and running on a live testnet) are in [prerequisites](docs/reference/prerequisites.md).

| Tool | Why | Check |
| --- | --- | --- |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) | Build, test, and every deploy/config script. | `forge --version` |
| Node.js + npm | Installs the Solidity dependencies (`npm ci`) and dev tooling. | `npm --version` |
| `make`, `bash`, `curl`, `jq` | The golden-path targets and the config/API sync (config sync needs no RPC, keystore, or API key). | `make tools` |
| A Foundry keystore account | Signing (`cast wallet import <name>`, used as `--account <name>`). Never a private key in `.env`. See [the signing decision](docs/decisions/0001-keystore-signing.md). | `cast wallet list` |

```bash
npm ci                       # install Solidity + dev dependencies
cp .env.example .env         # then set KEYSTORE_NAME, per-chain RPC URLs, and ETHERSCAN_API_KEY
forge build
```

## Quick start

Deploy a token and a BurnMint pool on two testnets, wire the lane, and send a transfer. Every command is
copy-pasteable. The `make` golden path resolves the RPC and keystore from each chain file's `rpcEnv`, so
you never hand-export an RPC per chain; the raw `forge script` each target wraps is documented on the
linked operations page as the escape hatch.

Run these for EACH of your two chains (`<chain>` is a selectorName such as `ethereum-testnet-sepolia`;
selectorNames may contain underscores, e.g. `binance_smart_chain-mainnet`; set
its `rpcEnv` and `KEYSTORE_NAME` in `.env`, then `source .env`).

1. **Onboard the chain from the CCIP API** ([operations/chains](docs/operations/chains.md)):

   ```bash
   make discover                                  # search the CCIP API chain catalog
   make add-chain CHAIN=<chain> SELECTOR=<sel>    # generate config/chains/<chain>.json from the API
   ```

2. **Deploy the token and its pool** ([tokens](docs/operations/tokens.md), [pools](docs/operations/pools.md)):

   ```bash
   make deploy-token CHAIN=<chain> TOKEN_NAME="My Token" TOKEN_SYMBOL=MTK
   make deploy-pool  CHAIN=<chain>        # BurnMint pool; token resolved from the registry
   make doctor       CHAIN=<chain>        # verify on-chain code at the recorded addresses
   ```

   `make deploy-new-chain CHAIN=<chain> SELECTOR=<sel>` runs `add-chain -> deploy-token -> deploy-pool ->
   doctor` end to end.

3. **Register the token with CCIP and set its pool** ([registration](docs/operations/registration.md)).
   Registration auto-detects the claim path (`getCCIPAdmin`, then `owner`, then AccessControl
   `DEFAULT_ADMIN_ROLE`):

   ```bash
   forge script script/setup/ClaimAndAcceptAdmin.s.sol --rpc-url $<CHAIN>_RPC_URL --account $KEYSTORE_NAME --broadcast
   forge script script/setup/SetPool.s.sol             --rpc-url $<CHAIN>_RPC_URL --account $KEYSTORE_NAME --broadcast
   ```

4. **Wire the lane** to the other chain (remote pool plus rate limits), on both sides
   ([lanes and remote pools](docs/operations/lanes-and-remotes.md)):

   ```bash
   make add-lane LOCAL=<chain> REMOTE=<other-chain> CAPACITY=<wei> RATE=<wei> BOTH=1
   forge script script/setup/ApplyChainUpdates.s.sol --rpc-url $<CHAIN>_RPC_URL --account $KEYSTORE_NAME --broadcast
   make doctor CHAIN=<chain>
   ```

5. **Send and track a transfer** ([send, track, and diagnose](docs/guides/send-track-diagnose.md)).
   Install `@chainlink/ccip-cli` (>= 1.10) for this step only; it is a testing tool, not a build
   dependency. Before the first real send, [preflight the transfer](docs/guides/preflight-a-transfer.md)
   with `make preflight` to prove the pools would release or mint:

   ```bash
   unset CCIP_API_URL
   ccip-cli send --source <chain> --dest <other-chain> --router <src-router> \
     --receiver <you> --transfer-tokens <token>=<amt> --approve-max
   ccip-cli show <messageId>        # or: curl -s https://api.ccip.chain.link/v2/messages/<messageId> | jq
   ```

## Production operations

The same primitives, parameterized by governance mode and hardened for a real launch. Each flow links its
operations page or guide with the exact commands.

- **Execution modes.** Every write primitive runs under EOA (default) or a Safe (`MODE=safe` emits one
  batch to sign). See [governance modes](docs/governance-modes.md).
- **Roles handoff (EOA to Safe).** Move the privileged roles to a Safe with the reviewed ceremony, then
  reconcile with `make roles-check`. See [roles](docs/roles.md).
- **Configure v2 pool features.** [Rate limits](docs/operations/rate-limits.md),
  [CCV](docs/operations/ccv.md), [hooks and allowlist](docs/operations/hooks-allowlist.md),
  [fees](docs/operations/fees.md), [finality](docs/operations/finality.md),
  [dynamic config](docs/operations/dynamic-config.md).
- **LockRelease liquidity.** The rebalancer and ERC20 LockBox models, side by side, in
  [liquidity](docs/operations/liquidity.md).
- **Mesh expansion.** Add or remove lanes in both directions, then reconcile with `make doctor`
  ([lanes and remote pools](docs/operations/lanes-and-remotes.md)).
- **Config sync.** Keep `config/chains` current against the CCIP API ([chains](docs/operations/chains.md)).
- **Verification.** Source-verify every deployed contract ([verification](docs/operations/verification.md)).
- **Pool migration.** Move a token from an old pool version to a new one without dropping in-flight
  messages ([migrate a pool](docs/guides/migrate-pool-v1-to-v2.md)).
- **Multiple tokens in one project.** Thread `GROUP=<g>` to keep each token group isolated; the
  [store model](docs/concepts/store-model.md) explains the config/project/history separation and the
  redeploy guard (`FORCE_REDEPLOY`).
- **Before mainnet.** Walk the [production checklist](docs/production-checklist.md).

## Documentation

- [Documentation map](docs/index.md) - the full index.
- [Primitives catalog](docs/primitives/index.md) - one page per script; [`catalog.json`](docs/primitives/catalog.json) for agents.
- [Guides](docs/guides/index.md) - task-focused how-tos.
- [Operations](docs/operations/tokens.md) - per-operation command reference.
- Reference: [prerequisites](docs/reference/prerequisites.md), [config and project-store schema](docs/config-schema.md), [config architecture](docs/config-architecture.md), [deployed addresses](docs/deployed-addresses.md), [pool versions](docs/pool-versions.md).
- Concepts: [composition](docs/concepts/composition.md), [store model](docs/concepts/store-model.md), [diagnosis](docs/concepts/diagnosis.md), [roles](docs/roles.md), [governance modes](docs/governance-modes.md).
- Learnings: [troubleshooting](docs/troubleshooting/index.md), [gotchas](docs/gotchas/index.md), [decisions](docs/decisions/0001-keystore-signing.md).

## Supported networks

The configured chains live in `config/chains/*.json`, each named by its canonical CCIP selectorName. Add
one with `make add-chain` (see [chains](docs/operations/chains.md)); the file name IS the selectorName, so
there are no bespoke slugs. Non-EVM chains (for example `solana-devnet`) are configured as adoption
targets.

## Testing

```bash
forge test            # full suite (fork tests read RPCs from .env)
npm run docs:gate     # primitives catalog freshness + docs links/anchors/prose
npm run lint:sol      # solhint (chainlink-ccip ruleset, zero warnings)
```
