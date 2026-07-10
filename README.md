# CCIP Cross-Chain Token Deployment and Registration Scripts

> **NOTE:** This repository represents an educational example to use a Chainlink system, product, or service and is provided to demonstrate how to interact with Chainlink’s systems, products, and services to integrate them into your own. This template is provided “AS IS” and “AS AVAILABLE” without warranties of any kind, it has not been audited, and it may be missing key checks or error handling to make the usage of the system, product or service more clear. Do not use the code in this example in a production environment without completing your own audits and application of best practices. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outputs that are generated due to errors in code.

Foundry scripts for deploying and managing cross-chain tokens using Chainlink CCIP.

## Prerequisites

Everything a fresh machine needs, in one place:

| Tool | Needed for | Check |
|---|---|---|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) | building, testing, and every deploy/config script | `forge --version` |
| Node.js + npm | installing the Solidity dependencies (`npm install`) | `npm --version` |
| `make` | the golden-path targets in the `Makefile` (preinstalled on macOS/Linux; on Windows use WSL) | `make --version` |
| `bash` | the thin wrapper scripts under `script/config/` | `bash --version` |
| `curl` + `jq` | **only** the chain-config sync tooling (fetching the [CCIP API](https://api.ccip.chain.link/v2)) — deploys don't use them | `curl --version`, `jq --version` |

The chain-config sync tooling (`make discover` / `add-chain` / `sync` / `sync-check` / `doctor`) needs **no RPC URL, no keystore, and no API key** — it only reads the public CCIP API. `make tools` runs this same presence check and prints install hints for anything missing.

1. Install [Foundry](https://book.getfoundry.sh/getting-started/installation)

2. Install dependencies:

    ```bash
    npm install
    ```

3. Create an encrypted Foundry keystore (if you don't have one already):

    ```bash
    cast wallet import your_keystore_name --interactive
    ```

4. Set up environment variables in `.env`. You can copy `.env.example` to `.env` and fill in your values:

    ```bash
    cp .env.example .env
    ```

    ```bash
    # Keystore name (created via `cast wallet import`)
    KEYSTORE_NAME=your_keystore_name

    # RPC URLs
    ETHEREUM_SEPOLIA_RPC_URL=your_eth_sepolia_rpc
    MANTLE_SEPOLIA_RPC_URL=your_mantle_sepolia_rpc

    # Etherscan API key (required only if you pass --verify to deployment scripts)
    ETHERSCAN_API_KEY=your_etherscan_api_key
    ```

5. Load environment variables:

    ```bash
    source .env
    ```


6. Build the project:

    ```bash
    forge build
    ```

## Deployment Flow

### Step 1: Deploy Token (on both chains)

Configure token parameters in `script/input/token.json` (see the [Configuration](#configuration) section), or override any field with environment variables:

| Env var | Default (from `token.json`) |
|---|---|
| `TOKEN_NAME` | `.name` |
| `TOKEN_SYMBOL` | `.symbol` |
| `TOKEN_DECIMALS` | `.decimals` |
| `TOKEN_MAX_SUPPLY` | `.maxSupply` |
| `TOKEN_PRE_MINT` | `.preMint` |
| `TOKEN_PRE_MINT_RECIPIENT` | broadcaster (if `TOKEN_PRE_MINT` > 0) |
| `CCIP_ADMIN_ADDRESS` | `msg.sender` (broadcaster) |

```bash
# Deploy on Ethereum Sepolia
forge script \
  script/deploy/DeployToken.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# Deploy on Mantle Sepolia
forge script \
  script/deploy/DeployToken.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

> **Note:** `--verify` requires `ETHERSCAN_API_KEY` to be set (see [Prerequisites](#prerequisites)). Etherscan API v2 supports all chains with a single key.

Optional: Set `ROLES_RECIPIENT` to grant mint/burn roles to a specific address (defaults to the deployer).

After each deployment, the token address is automatically saved to:
```
script/deployments/tokens/{CHAIN_NAME_IDENTIFIER}/{timestamp}-{SYMBOL}-Token.json
```
The file uses the env var name as the key (e.g. `ETHEREUM_SEPOLIA_TOKEN`). If you need to retrieve the deployed address later, open the file — the key is the env var name and the value is the address, so you can copy both directly into an `export` command. The `script/deployments/` directory is ignored by `.gitignore` — files are local to each user.

A broadcast deploy also records the address in the [address registry](#deployed-address-registry--addresseschainidjson-the-default) (`addresses/<chainId>.json`), so **subsequent scripts resolve the token automatically — no `export` needed**. Re-running the deploy on the same chain is refused while the registry holds a live address (set `FORCE_REDEPLOY=true` to deploy a replacement).

To override the registry address for a session, choose one approach:

```bash
# Option A: export for the session (persists across all commands in the current terminal)
export ETHEREUM_SEPOLIA_TOKEN=0x...
export MANTLE_SEPOLIA_TOKEN=0x...

# Option B: inline alias per command (no export needed; applies to that one command only)
TOKEN=0x... forge script script/setup/ClaimAdmin.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
```

### Step 2: Deploy Token Pools (on both chains)

##### Burn & Mint Pool

Tokens are burned on source, minted on destination.

```bash
# Deploy pool on Ethereum Sepolia
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# Deploy pool on Mantle Sepolia
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

After each deployment, the pool address is automatically saved to:
```
script/deployments/token-pools/{CHAIN_NAME_IDENTIFIER}/{timestamp}-{SYMBOL}-BurnMintTokenPool.json
```
The file records the pool address under `{CHAIN_NAME_IDENTIFIER}_TOKEN_POOL` and its bound token address under `{CHAIN_NAME_IDENTIFIER}_TOKEN`.

Optional: Set `POOL_HOOKS=0x...` to attach an `AdvancedPoolHooks` contract at deploy time. Set `DECIMALS=<n>` if your token does not implement the optional `decimals()` ERC20 function — the script will fall back to this value and fail if neither is available.

The script also attempts to call `grantMintAndBurnRoles` on the token to grant the pool mint and burn rights. If the token does not implement this function, the script will print instructions to grant the roles manually.

##### Lock & Release Pool

Use the following when you don't have burn/mint rights on the source chain token (e.g. it was issued by a third party). Two patterns are supported:

###### Pattern A — Lock on Source, Mint on Destination

Token was originally issued on one chain; you control the token on the destination and can grant mint rights.

The `ERC20LockBox` is only needed on the chain where tokens are **locked**. The destination chain uses a standard `BurnMintTokenPool`, which requires mint/burn rights on the destination token.

```bash
# 1. Deploy ERC20LockBox first (pool address isn't known yet)
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
# Optional: add AUTHORIZED_CALLERS=<DEPLOYER_OR_TOKEN_ISSUER_EOA> to the command above to authorize initial liquidity deposits/withdrawals

# 2. Deploy LockRelease pool, passing the lockbox address from step 1
LOCK_BOX=<LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 3. Authorize the pool to call the lockbox (deposit/withdraw)
LOCK_BOX=<LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# 4. BurnMint pool on Mantle Sepolia (minting side)
forge script \
  script/deploy/DeployBurnMintTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

###### Pattern B — Lock on Source, Release on Destination

Token already exists on both chains independently.

Each chain needs its own `ERC20LockBox` and `LockReleaseTokenPool`.

```bash
# 1. Deploy ERC20LockBox on Ethereum Sepolia
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 2. Deploy ERC20LockBox on Mantle Sepolia
forge script \
  script/deploy/DeployERC20LockBox.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# Optional: add AUTHORIZED_CALLERS=<DEPLOYER_OR_TOKEN_ISSUER_EOA> to either or both commands below for initial liquidity management

# 3. Deploy LockRelease pool on Ethereum Sepolia, passing its lockbox address from step 1
LOCK_BOX=<ETHEREUM_SEPOLIA_LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 4. Authorize the Ethereum Sepolia pool on its lockbox
LOCK_BOX=<ETHEREUM_SEPOLIA_LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<ETHEREUM_SEPOLIA_POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# 5. Deploy LockRelease pool on Mantle Sepolia, passing its lockbox address from step 2
LOCK_BOX=<MANTLE_SEPOLIA_LOCKBOX_ADDRESS> \
  forge script \
  script/deploy/DeployLockReleaseTokenPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify

# 6. Authorize the Mantle Sepolia pool on its lockbox
LOCK_BOX=<MANTLE_SEPOLIA_LOCKBOX_ADDRESS> \
  ADD_ADDRESSES=<MANTLE_SEPOLIA_POOL_ADDRESS> \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

The `LockReleaseTokenPool` requires the `ERC20LockBox` at deploy time, and the lockbox must authorize the pool (via `UpdateAuthorizedCallers`) before it can deposit/withdraw tokens. The deployment order is always: **lockbox → pool → authorize pool on lockbox**.

`LOCK_BOX` is required and must be the address of a deployed `ERC20LockBox` for the token. Optional: Set `POOL_HOOKS=0x...` to attach an already-deployed `AdvancedPoolHooks` contract at deploy time. Set `DECIMALS=<n>` if your token does not implement the optional `decimals()` ERC20 function. When deploying the lockbox, you can optionally set `AUTHORIZED_CALLERS` (CSV or JSON array) to authorize addresses immediately — useful for authorizing the deployer or token issuer to deposit/withdraw liquidity initially.

A broadcast deploy records the pool (and lockbox) address in the [address registry](#deployed-address-registry--addresseschainidjson-the-default), so **subsequent scripts resolve it automatically — no `export` needed** (the LockRelease pool deploy also resolves `LOCK_BOX` from the registry). To override the registry address for a session, choose one approach:

```bash
# Option A: export for the session (persists across all commands in the current terminal)
export ETHEREUM_SEPOLIA_TOKEN_POOL=0x...
export MANTLE_SEPOLIA_TOKEN_POOL=0x...

# Option B: inline alias per command (no export needed; applies to that one command only)
TOKEN_POOL=0x... forge script script/setup/SetPool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
```

Each deployment is automatically saved:
- ERC20LockBox → `script/deployments/lock-boxes/{CHAIN_NAME_IDENTIFIER}/{timestamp}-{SYMBOL}-LockBox.json` — keys: `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`
- LockReleaseTokenPool → `script/deployments/token-pools/{CHAIN_NAME_IDENTIFIER}/{timestamp}-{SYMBOL}-LockReleaseTokenPool.json` — keys: `{CHAIN_NAME_IDENTIFIER}_TOKEN_POOL`, `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`

To verify the lockbox address is correctly attached to the pool:

```bash
forge script script/configure/GetLockBox.s.sol --rpc-url $MANTLE_SEPOLIA_RPC_URL
```

### Step 3: Claim Admin (on both chains)

```bash
# On Ethereum Sepolia
forge script \
  script/setup/ClaimAdmin.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/ClaimAdmin.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Optional: Set `CCIP_ADMIN_ADDRESS=0x...` to specify the token's current admin address (defaults to the EOA broadcasting the transaction).

### Step 4: Accept Admin Role (on both chains)

```bash
# On Ethereum Sepolia
forge script \
  script/setup/AcceptAdminRole.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/AcceptAdminRole.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Step 5: Apply Chain Updates (configure cross-chain routes)

```bash
# Configure Ethereum Sepolia → Mantle Sepolia
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Configure Mantle Sepolia → Ethereum Sepolia
DEST_CHAIN=ETHEREUM_SEPOLIA \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Configure Ethereum Sepolia → Solana Devnet (non-EVM destination)
DEST_CHAIN=SOLANA_DEVNET \
  SOLANA_DEVNET_TOKEN_POOL=<SOLANA_TOKEN_POOL_ADDRESS> \
  SOLANA_DEVNET_TOKEN=<SOLANA_TOKEN_ADDRESS> \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

> **Non-EVM destinations:** For non-EVM chains like Solana Devnet, supply the destination pool and token addresses via `{DEST_CHAIN}_TOKEN_POOL` and `{DEST_CHAIN}_TOKEN` (e.g. `SOLANA_DEVNET_TOKEN_POOL`, `SOLANA_DEVNET_TOKEN`). These are base58-encoded addresses — not `0x`-prefixed EVM addresses. Rate limiting is not applicable for non-EVM destinations and is ignored.

This script is idempotent — if the destination chain is already configured on the pool, the existing config is removed and replaced automatically.

Rate limiting is disabled by default. To enable it, pass the capacity and rate — `isEnabled` is automatically set to `true` when either value is provided:

```bash
# Ethereum Sepolia → Mantle Sepolia: enable both directions
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Mantle Sepolia → Ethereum Sepolia: enable both directions
DEST_CHAIN=ETHEREUM_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Enable outbound only (Sepolia → Mantle)
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Enable inbound only (Sepolia → Mantle)
DEST_CHAIN=MANTLE_SEPOLIA \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/setup/ApplyChainUpdates.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var | Required | Description |
|---|---|---|
| `DEST_CHAIN` | Yes | Destination chain name (e.g. `MANTLE_SEPOLIA`) |
| `TOKEN_POOL` | No | Inline alias for the source chain pool address. Takes priority over `{CHAIN}_TOKEN_POOL`. |
| `DEST_TOKEN_POOL` | No | Inline alias for the destination chain pool address. Takes priority over `{DEST_CHAIN}_TOKEN_POOL`. |
| `DEST_TOKEN` | No | Inline alias for the destination chain token address. Takes priority over `{DEST_CHAIN}_TOKEN`. |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No | Token bucket capacity for outbound transfers |
| `OUTBOUND_RATE_LIMIT_RATE` | No | Token bucket refill rate (tokens/second) for outbound transfers |
| `OUTBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |
| `INBOUND_RATE_LIMIT_CAPACITY` | No | Token bucket capacity for inbound transfers |
| `INBOUND_RATE_LIMIT_RATE` | No | Token bucket refill rate (tokens/second) for inbound transfers |
| `INBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |

> **Note:** `ApplyChainUpdates` only configures the **standard finality** rate limit bucket. To configure the fast finality bucket, run `UpdateRateLimiters` with `FAST_FINALITY=true` after the lane is set up.

To read the list of supported chains and their remote pool addresses:

```bash
forge script script/setup/GetSupportedChains.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

### Step 6: Set Pool (on both chains)

```bash
# On Ethereum Sepolia
forge script \
  script/setup/SetPool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# On Mantle Sepolia
forge script \
  script/setup/SetPool.s.sol \
  --rpc-url \
  $MANTLE_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

## Adding a New Chain

Supporting a new chain is a **config edit, not a code change** — three commands generate and verify `config/chains/<name>.json` from the live [CCIP API](https://api.ccip.chain.link/v2) (needs only `curl` + `jq` from the [Prerequisites](#prerequisites) — no RPC URL, no keystore, no API key):

```bash
make discover FILTER=base            # 1. find the chain in the API catalog, note its NAME + SELECTOR
make add-chain CHAIN=ethereum-testnet-sepolia-base-1 SELECTOR=10344971235874465080   # 2. generate from the API
make doctor CHAIN=ethereum-testnet-sepolia-base-1   # 3. layered verification — re-run until green
```

`CHAIN` is the chain's **canonical CCIP selectorName** as shown by `make discover` (the API/registry name — e.g. `ethereum-testnet-sepolia-base-1`, not a bespoke `base-sepolia`); it becomes the file name `config/chains/<CHAIN>.json` and is validated against the API. `SELECTOR` is the **explicit identity key**, also from `make discover` — every fetch cross-checks both: a valid-but-wrong selector fails loudly as `SELECTOR MISMATCH`, and a non-canonical name as `SELECTOR NAME MISMATCH`, instead of silently writing another chain's contracts. New chains are **discovered automatically** from `config/chains/` — `HelperConfig` scans the directory, so no Solidity edit is needed anywhere. For a newly added chain the `chainNameIdentifier` (and hence the `rpcEnv` and the `<ID>_TOKEN`/`<ID>_TOKEN_POOL` override prefix) is **derived from the selectorName** as UPPER_SNAKE — so it may differ in style from the six bundled chains' curated short forms (e.g. `AVALANCHE_TESTNET_FUJI`, not `AVALANCHE_FUJI`); `add-chain` **prints the exact `chainNameIdentifier` and `rpcEnv` names it generated** so you never have to guess (or open the JSON) which env var to export. `add-chain` prints your next steps: add the chain's RPC env var to `.env`, then deploy your token and pool there ([Step 1](#step-1-deploy-token-on-both-chains) / [Step 2](#step-2-deploy-token-pools-on-both-chains)). Wiring the new chain into your cross-chain lanes ([Step 5](#step-5-apply-chain-updates-configure-cross-chain-routes)) stays a manual flow for now — a scripted lane-wiring golden path lands in a follow-up.

Full details: [Configuration](#configuration) overview, the per-field [`docs/config-schema.md`](docs/config-schema.md), and the command + architecture reference [`docs/config-architecture.md`](docs/config-architecture.md).

### Which command when

| I want to... | Run |
|---|---|
| See which chains exist / find a selector | `make discover FILTER=<term>` |
| Onboard a new chain | `make add-chain CHAIN=<name> SELECTOR=<sel>`, then `make doctor CHAIN=<name>` |
| Check whether any config drifted from the API (routine; what CI runs weekly) | `make sync-check` (CI/automation: `bash script/config/sync-check.sh` for the 0/1/2 exit codes) |
| Inspect what the API currently has for one chain before changing anything | `make sync-preview CHAIN=<name>` |
| Apply the API's current values | `make sync CHAIN=<name>` / `make sync-all` |
| Deep-verify one chain end to end (human health check) | `make doctor CHAIN=<name>` |
| Restore canonical formatting after a raw `forge script` run | `make fmt-config` |

`doctor` and `sync-check` layer rather than overlap: `doctor` is the deep single-chain health check for a human (schema, identity, drift, RPC, on-chain code, registry warnings), while `sync-check` is the fleet-wide drift verdict for routine use and CI.

## Ownership Management (Optional)

The following scripts are not required for the core deployment flow but are useful when handing off control to a multisig or a different EOA after initial setup. All token ownership scripts auto-detect the correct ownership pattern — no configuration needed.

### Transfer Ownership

Initiates an ownership transfer for a token, token pool, pool hooks, or lockbox. Use `ENTITY_TYPE` to specify which entity to transfer, and `ADDRESS` to specify the contract address. If `ENTITY_TYPE` is omitted, the contract is treated as a generic `IOwnable` — the same path used for `tokenPool`, `poolHooks`, and `lockBox`.

For token transfers, the script auto-detects the token type and calls the appropriate function:

| Detection | Token type | Transfer action | Accept required? |
|---|---|---|---|
| `pendingDefaultAdmin()` succeeds | CrossChainToken | `beginDefaultAdminTransfer` | Yes — run `AcceptOwnership` |
| `pendingOwner()` + `owner()` succeed | OZ `Ownable2Step` | `transferOwnership` | Yes — run `AcceptOwnership` |
| `owner()` only (no `pendingOwner()`) | `ConfirmedOwner` or plain `Ownable` | `transferOwnership` | Yes for `ConfirmedOwner`; plain `Ownable` transfers immediately |
| Neither | `BurnMintERC20` v1 (plain `AccessControl`) | `grantRole` + `revokeRole` (atomic, 1-step) | No |

For `tokenPool`, `poolHooks`, and `lockBox`: uses Chainlink's `ConfirmedOwner` (two-step) — always requires `AcceptOwnership`.

**Step 1 — initiate (run as current owner/admin):**

```bash
# Omit ENTITY_TYPE to use the generic IOwnable path (works for any tokenPool/poolHooks/lockBox)
ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Or specify ENTITY_TYPE for a named label in the output
# Token pool
ENTITY_TYPE=tokenPool ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Token
ENTITY_TYPE=token ADDRESS=0xYourToken NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Pool hooks
ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# LockBox
ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox NEW_OWNER=0xNewOwner \
  forge script \
  script/setup/transfer-ownership/TransferOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast
```

**Step 2 — accept (run as `NEW_OWNER`):**

```bash
# Omit ENTITY_TYPE to use the generic IOwnable path
ADDRESS=0xYourPool \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Or specify ENTITY_TYPE for a named label in the output
# Token pool
ENTITY_TYPE=tokenPool ADDRESS=0xYourPool \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Token
ENTITY_TYPE=token ADDRESS=0xYourToken \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# Pool hooks
ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast

# LockBox
ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox \
  forge script \
  script/setup/transfer-ownership/AcceptOwnership.s.sol \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --account $KEYSTORE_NAME \
  --broadcast
```

> For `BurnMintERC20` v1, step 2 exits early — the transfer was already atomic. For plain `Ownable`, step 1 completes immediately — step 2 will revert on-chain.

### Transfer Token Admin Role

Initiates a transfer of the CCIP token admin role to a new address. This is step 1 of a two-step process — the new admin must run `AcceptAdminRole` to complete it.

```bash
NEW_ADMIN=0xNewAdminAddress \
  forge script \
  script/setup/TransferTokenAdminRole.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Optional: Set `TOKEN=0x...` to override the token address (defaults to the `{CHAIN}_TOKEN` env var).

## Token Operations

### Mint Tokens

```bash
forge script \
  script/operations/MintTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Optional: Set `AMOUNT` to override the amount to mint (defaults to `tokenAmountToMint` from `script/input/token.json`). Set `MINT_RECEIVER` to mint to a different address (defaults to the EOA broadcasting the transaction).

### Transfer Tokens Cross-Chain

Install `ccip-cli` globally if not already installed:

```bash
npm install -g @chainlink/ccip-cli
```

> **Minimum version:** This README assumes `@chainlink/ccip-cli >= 1.5.0` (supports `--extra finality=...`).
> Verify your version with:
>
> ```bash
> ccip-cli --version
> ```

First, export the router address for the source chain — find it in `HelperConfig.s.sol` or the [CCIP Directory](https://docs.chain.link/ccip/directory), for example:

```bash
export ETHEREUM_SEPOLIA_ROUTER=0x...
```

```bash
# Receiver address
export RECEIVER=0xYourReceiverAddress

# The Foundry scripts use smallest-unit amounts (wei-like). In the ccip-cli example below, we use a compact, human-readable token amount
ccip-cli send \
  --source ethereum-testnet-sepolia \
  --router $ETHEREUM_SEPOLIA_ROUTER \
  --dest ethereum-testnet-sepolia-mantle-1 \
  --transfer-tokens $ETHEREUM_SEPOLIA_TOKEN=1.23 \
  --receiver $RECEIVER \
  --wallet foundry:$KEYSTORE_NAME
```

Finality options (`--extra finality=...`):

- `finality=finalized` (default): Wait for full finality.
- `finality=safe`: Use Fast Confirmation Rule (wait for the `safe` head).
- `finality=<blockDepth>`: Wait for N block confirmations (example: `finality=5`).

Omit `-x finality=<n>` to use default finality. When set, `<n>` must be greater than or equal to the pool's configured block depth (see [Set Finality Config](#manage-finality-config)). Pass `--fee-token LINK` to pay fees with LINK (defaults to the native network token).

See the [CCIP CLI docs](https://docs.chain.link/ccip/tools/cli/) for more details.

### Deposit to LockBox

Manually deposit tokens into an ERC20LockBox. Useful for token issuers managing liquidity.

```bash
LOCK_BOX=0x... \
  forge script \
  script/operations/DepositToLockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Optional: Set `AMOUNT` to override the amount to deposit (defaults to `tokenAmountToTransfer` from `script/input/token.json`). Requires the broadcaster to be an authorized caller on the lockbox.

### Withdraw from LockBox

Manually withdraw tokens from an ERC20LockBox. Useful for token issuers managing liquidity.

```bash
LOCK_BOX=0x... \
  forge script \
  script/operations/WithdrawFromLockBox.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

By default, withdraws the entire lockbox balance. Optional: Set `AMOUNT` to withdraw a specific amount instead. Set `RECIPIENT=0x...` to send withdrawn tokens to a different address (defaults to broadcaster). Requires the broadcaster to be an authorized caller on the lockbox.

### Get Fee Token Balances

Inspect the fee token balances held by a token pool. Run this before `WithdrawFeeTokens` — it prints each token's balance and a pre-filled withdrawal command for any non-zero tokens.

```bash
FEE_TOKENS="0xTokenA,0xTokenB" \
  forge script \
  script/operations/GetFeeTokenBalances.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

### Withdraw Fee Tokens

Withdraws accrued fee token balances from a token pool to a specified recipient. Only callable by the pool owner or the designated fee admin.

> **Note:** Pool-level fee accrual and withdrawal are introduced in TokenPool v2.0. If run against a v1 pool, the script will exit with an informative message and suggest using FeeQuoter instead.

This script makes no assumptions about which token(s) have accumulated as fees — you must explicitly specify them via `FEE_TOKENS`. Accepts a comma-separated list or JSON array.

```bash
# Single fee token
RECIPIENT=0xYourAddress \
  FEE_TOKENS="0xTokenThatAccruedFees" \
  forge script \
  script/operations/WithdrawFeeTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Multiple fee tokens
RECIPIENT=0xYourAddress \
  FEE_TOKENS="0xFirstFeeToken,0xSecondFeeToken" \
  forge script \
  script/operations/WithdrawFeeTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var | Required | Description |
|---|---|---|
| `FEE_TOKENS` | Yes | CSV or JSON array of ERC20 token addresses to withdraw |
| `RECIPIENT` | No | Address to receive the withdrawn fee tokens (defaults to the broadcaster) |

The pool token address is printed at runtime for reference so you can identify whether to include it in `FEE_TOKENS`.

## Optional Configuration

### Manage Dynamic Config

Reads or updates the dynamic configuration on a token pool: the CCIP router, rate limit admin, and fee admin.

##### View Dynamic Config

```bash
forge script script/configure/dynamic-config/GetDynamicConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

##### Set Dynamic Config

```bash
ROUTER=0xYourRouterAddress \
  forge script \
  script/configure/dynamic-config/SetDynamicConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var | Required | Description |
|---|---|---|
| `ROUTER` | No | The CCIP router address to set on the pool (default: current on-chain value) |
| `RATE_LIMIT_ADMIN` | No | Rate limit admin address (default: current on-chain value, then broadcaster) |
| `FEE_ADMIN` | No | Fee admin address (default: current on-chain value, then broadcaster). Set to `address(0)` to restrict fee withdrawal to the owner only |

### Manage Finality Config

> **Note:** Requires TokenPool v2.0 or later. The finality config controls which fast finality modes are accepted for cross-chain transfers. Setting it to `WAIT_FOR_FINALITY` (no env vars, the default) disables fast finality transfers.

##### View Finality Config

```bash
forge script script/configure/finality-config/GetFinalityConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

##### Set Finality Config

> **Best practice:** When enabling fast finality, consider configuring the fast finality bucket rate limits at the same time. If the fast finality bucket is not configured, fast finality transfers fall back to the standard finality bucket. Configuring it explicitly gives you isolated, independently tuned rate limits for fast finality transfers — useful when their volume or risk profile differs from standard finality transfers.

```bash
# Set block depth and configure the fast finality rate limit bucket:
BLOCK_DEPTH=5 \
  DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Set block depth only (no rate limit changes):
BLOCK_DEPTH=5 \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Set WAIT_FOR_SAFE mode and view current rate limits for a lane (no update):
WAIT_FOR_SAFE=true \
  DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Combine BLOCK_DEPTH and WAIT_FOR_SAFE (pool accepts either mode simultaneously):
BLOCK_DEPTH=5 \
  WAIT_FOR_SAFE=true \
  forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Reset to default finality (disables fast finality transfers):
forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

When `DEST_CHAIN` is provided, the script logs the current rate limits before applying any changes, and the updated state after. Each direction is shown independently: the **fast finality bucket** is displayed for directions where it is enabled; the **standard finality bucket** (fallback) is displayed for directions where it is not.

| Env var | Required | Description |
|---|---|---|
| `BLOCK_DEPTH` | No | Number of block confirmations for fast finality (1–65535). Can be combined with `WAIT_FOR_SAFE` to allow both modes simultaneously. Omit both to reset to default finality. |
| `WAIT_FOR_SAFE` | No | Set to `true` to use the `safe` head for fast finality. Can be combined with `BLOCK_DEPTH` to allow both modes simultaneously. |
| `DEST_CHAIN` | No | Remote chain whose lane is queried/updated (e.g. `MANTLE_SEPOLIA`). Required when any rate limit var is set; if omitted, the rate limiter section is skipped entirely |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No | uint128, outbound token bucket capacity (fast finality bucket) |
| `OUTBOUND_RATE_LIMIT_RATE` | No | uint128, outbound token bucket refill rate (tokens/second) |
| `OUTBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set) |
| `INBOUND_RATE_LIMIT_CAPACITY` | No | uint128, inbound token bucket capacity (fast finality bucket) |
| `INBOUND_RATE_LIMIT_RATE` | No | uint128, inbound token bucket refill rate (tokens/second) |
| `INBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set) |

### Manage Remote Pools

Remote pools represent the pool addresses registered on a given chain for each supported remote chain. When a pool is upgraded on a remote chain, the old address should be kept active until all inflight messages have completed, then removed.

##### View Remote Pools

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/remote-pools/GetRemotePools.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

##### Add a Remote Pool

Use after upgrading a pool on a remote chain. Both the old and new pool addresses can be active simultaneously to allow inflight messages to complete.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  REMOTE_POOL_ADDRESS=0xNewRemotePoolAddress \
  forge script \
  script/configure/remote-pools/AddRemotePool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

##### Remove a Remote Pool

> **Warning:** All inflight transactions from the removed pool will be rejected after removal. Ensure there are no inflight transactions before proceeding.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  REMOTE_POOL_ADDRESS=0xOldRemotePoolAddress \
  forge script \
  script/configure/remote-pools/RemoveRemotePool.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Deploy Advanced Pool Hooks

Use this script for enhanced security features like allowlists, CCV management, policy engine integration, and threshold-based validation.

Configure defaults in `script/input/advanced-pool-hooks.json` (see the [Configuration](#configuration) section), or override any field with environment variables:

| Env var | Type | Default (from `advanced-pool-hooks.json`) |
|---|---|---|
| `ALLOWLIST` | CSV or JSON array | `.allowlist` |
| `AUTHORIZED_CALLERS` | CSV or JSON array | `.authorizedCallers` |
| `THRESHOLD_AMOUNT` | uint256 | `.thresholdAmount` |
| `POLICY_ENGINE` | address | `.policyEngine` |

> **Important:** The `allowlistEnabled` flag is set **immutably** at deploy time based on whether `ALLOWLIST` is non-empty. If you deploy with an empty allowlist (the default), allowlist functionality is permanently disabled — subsequent calls to `UpdateAllowList` will always revert. To enable allowlisting, pass at least one address via `ALLOWLIST` at deploy time.

```bash
forge script \
  script/configure/allowlist/DeployAdvancedPoolHooks.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast \
  --verify
```

After deployment, the hooks address is automatically saved to:
```
script/deployments/advanced-pool-hooks/{CHAIN_NAME_IDENTIFIER}/{timestamp}-AdvancedPoolHooks.json
```
The file records the address under the `POOL_HOOKS` key.

Then pass the hooks address as `POOL_HOOKS` when [deploying a new token pool](#step-2-deploy-token-pools-on-both-chains), or connect it to an existing pool via [`UpdateAdvancedPoolHooks`](#connect-advanced-pool-hooks-to-a-token-pool).

### Get Advanced Pool Hooks

Reads and displays the `AdvancedPoolHooks` contract address currently attached to a token pool.

```bash
forge script script/configure/allowlist/GetAdvancedPoolHooks.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

### Connect Advanced Pool Hooks to a Token Pool

```bash
TOKEN_POOL=0x... \
  NEW_HOOK=0x... \
  forge script \
  script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Manage Allowlist

##### Add/Remove Addresses

Supports CSV or JSON array.

```bash
# Via AdvancedPoolHooks
POOL_HOOKS=0x... \
  ADD_ADDRESSES="0xAAA...,0xBBB..." \
  forge script \
  script/configure/allowlist/UpdateAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove addresses
POOL_HOOKS=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/allowlist/UpdateAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

> If `POOL_HOOKS` is not set, the script falls back to calling directly on the `TOKEN_POOL` (v1 pools only).

##### View Current Allowlist

```bash
POOL_HOOKS=0x... \
  forge script \
  script/configure/allowlist/GetAllowList.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```

##### Check if an Address Is Allowlisted

```bash
POOL_HOOKS=0x... \
  CHECK_ADDRESS=0x... \
  forge script \
  script/configure/allowlist/IsAllowListed.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```

### Manage Authorized Callers

`AuthorizedCallers` is used in two places:
- **`AdvancedPoolHooks`** — authorized callers are the token pools permitted to invoke the hooks.
- **`ERC20LockBox`** — authorized callers are the `LockReleaseTokenPool` contracts permitted to call `deposit`/`withdraw`.

Both use the same scripts, passing either `POOL_HOOKS=<hooksAddress>` or `LOCK_BOX=<lockBoxAddress>`.

##### Add/Remove Authorized Callers

Supports CSV or JSON array.

```bash
# Add callers — AdvancedPoolHooks
POOL_HOOKS=0x... \
  ADD_ADDRESSES="0xAAA...,0xBBB..." \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Add callers — ERC20LockBox
LOCK_BOX=0x... \
  ADD_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove callers — AdvancedPoolHooks
POOL_HOOKS=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Remove callers — ERC20LockBox
LOCK_BOX=0x... \
  REMOVE_ADDRESSES=0xAAA... \
  forge script \
  script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

##### View Current Authorized Callers

```bash
# AdvancedPoolHooks
POOL_HOOKS=0x... \
  forge script \
  script/configure/authorized-callers/GetAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME

# ERC20LockBox
LOCK_BOX=0x... \
  forge script \
  script/configure/authorized-callers/GetAuthorizedCallers.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME
```

### Manage Rate Limiters

##### View Current Rate Limits

Reads and displays the current rate limiter state for a token pool lane. Compatible with both v1 and v2 pools.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/rate-limiter/GetCurrentRateLimits.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

Optional: Set `FAST_FINALITY=true` to query the fast finality bucket (v2 pools only). Each direction is shown independently: the fast finality bucket is displayed where it is enabled; the standard finality bucket (fallback) is displayed where it is not.

##### Update Rate Limits

Updates rate limiter configuration for a specific lane. Compatible with both v1 and v2 pools. The direction is inferred automatically from whichever `OUTBOUND_*` / `INBOUND_*` vars are set — no need to pass `ENABLED` separately. `isEnabled` defaults to `true` when `CAPACITY` or `RATE` are provided; pass `ENABLED=false` to explicitly disable.

```bash
# Enable both directions (ENABLED is optional — defaults to true when CAPACITY/RATE are set)
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  OUTBOUND_RATE_LIMIT_RATE=100000000000000000 \
  INBOUND_RATE_LIMIT_CAPACITY=1000000000000000000000 \
  INBOUND_RATE_LIMIT_RATE=100000000000000000 \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable outbound only
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable inbound only
DEST_CHAIN=MANTLE_SEPOLIA \
  INBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Disable both directions
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_RATE_LIMIT_ENABLED=false \
  INBOUND_RATE_LIMIT_ENABLED=false \
  forge script \
  script/configure/rate-limiter/UpdateRateLimiters.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var | Required | Description |
|---|---|---|
| `DEST_CHAIN` | Yes | Remote chain whose lane is being updated |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | To update outbound | Token bucket capacity for outbound transfers |
| `OUTBOUND_RATE_LIMIT_RATE` | To update outbound | Token bucket refill rate (tokens/second) for outbound transfers |
| `OUTBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |
| `INBOUND_RATE_LIMIT_CAPACITY` | To update inbound | Token bucket capacity for inbound transfers |
| `INBOUND_RATE_LIMIT_RATE` | To update inbound | Token bucket refill rate (tokens/second) for inbound transfers |
| `INBOUND_RATE_LIMIT_ENABLED` | No | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set) |
| `FAST_FINALITY` | No | `true` to update the fast finality bucket instead of the standard finality bucket (v2 only, default: `false`) |

### Manage Token Transfer Fee Config

Token pools v2.0 and later allow token issuers to configure fee parameters directly on the pool, overriding FeeQuoter defaults. If run against a v1 pool, these scripts will exit with an informative message — on v1, fee configuration is managed entirely by FeeQuoter and must be requested from the Chainlink team.

##### View Fee Config

Reads the raw stored fee configuration for a destination lane.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/fee-config/GetTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

##### Set or Update Fee Config

All fee config env vars are optional — unset fields default to the current on-chain values, so you only need to pass the fields you want to change. When setting a fee config for the first time (no existing on-chain config), any unset fields default to `0`.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  DEST_GAS_OVERHEAD=50000 \
  DEST_BYTES_OVERHEAD=32 \
  FINALITY_FEE_USD_CENTS=0 \
  FAST_FINALITY_FEE_USD_CENTS=1000 \
  FINALITY_TRANSFER_FEE_BPS=0 \
  FAST_FINALITY_TRANSFER_FEE_BPS=1000 \
  forge script \
  script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var | Required | Description |
|---|---|---|
| `DEST_CHAIN` | Yes | Remote chain to configure fees for |
| `DEST_GAS_OVERHEAD` | No | Gas overhead charged on the destination chain (must be > 0; defaults to current on-chain value) |
| `DEST_BYTES_OVERHEAD` | No | Data availability bytes overhead (defaults to current on-chain value) |
| `FINALITY_FEE_USD_CENTS` | No | Flat fee in 0.01 USD units for finality transfers (defaults to current on-chain value) |
| `FAST_FINALITY_FEE_USD_CENTS` | No | Flat fee in 0.01 USD units for fast finality transfers (defaults to current on-chain value) |
| `FINALITY_TRANSFER_FEE_BPS` | No | Fee in basis points deducted from the transferred amount for finality transfers [0–9999] (defaults to current on-chain value) |
| `FAST_FINALITY_TRANSFER_FEE_BPS` | No | Fee in basis points deducted from the transferred amount for fast finality transfers [0–9999] (defaults to current on-chain value) |
| `DISABLE` | No | Set to `true` to disable the fee config for this lane, reverting the OnRamp to FeeQuoter defaults (default: `false`) |

##### Disable Fee Config

Disabling the fee config for a lane causes the OnRamp to fall back to FeeQuoter defaults.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  DISABLE=true \
  forge script \
  script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

## Supported Networks

**EVM chains (source or destination):**

- Ethereum Sepolia (`ETHEREUM_SEPOLIA`)
- Mantle Sepolia (`MANTLE_SEPOLIA`)

**Non-EVM chains (destination only):**

> Non-EVM chains can only be used as the **destination** chain in `ApplyChainUpdates` — i.e. to register a non-EVM token pool on an EVM source chain. They cannot be used as source chains in this repo.

- Solana Devnet (`SOLANA_DEVNET`)

## Configuration

The repo keeps its cross-chain state as **data, not code**, in two git-visible stores:

- **`config/chains/<selectorName>.json`** — one reviewed file per chain: the API-synced `ccip{}` address block + API-synced identity/metadata (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`), and the hand-authored keys (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`). Files are named by the canonical CCIP **selectorName** (e.g. `ethereum-testnet-sepolia.json`). `HelperConfig` reads them through `src/config/ChainConfig.sol` and discovers the chain list by scanning the directory, so adding a chain — or updating a CCIP address — is a **reviewed config edit with zero Solidity changes**.
- **`addresses/<chainId>.json`** — the deployed-address registry (schema v2: `active` role pointers + versioned `deployments`), written automatically on a real broadcast via a single `DeploymentRecorder` call per artifact (user-specific, **gitignored**, local to the deploy machine; see `addresses/11155111.example.json`).

**One writer per field:** the CCIP REST API owns **every field it serves** in the **git-tracked** `config/chains/*.json` (via the sync) — the `ccip{}` addresses AND the identity/metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`); only the keys the API serves nothing for (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`) are hand-authored in reviewed PRs, and the join keys are guard-validated — so for that file **a git diff is an unambiguous audit log**. The deployed-address registry `addresses/` is a **separate, gitignored** store (not a git audit trail); its integrity comes from a single writer — the `DeploymentRecorder` that emits the `script/deployments/**` ledger and the registry entry in one call. Environment variables remain available as **overrides** on top of both.

> **Reference docs:** **[`docs/config-schema.md`](docs/config-schema.md)** is the per-field reference (every key in a chain config — identity, the `ccip{}` block, extras, and the non-EVM shape — with its type, writer, and whether it is API-synced, hand-authored, or deploy-written); **[`docs/config-architecture.md`](docs/config-architecture.md)** is the `make`-command reference plus the layered architecture (brand-colored Mermaid diagrams: layering, sync data-flow, the one-writer store model, and the selectorName join). The operational how-to (discover → add-chain → sync → doctor) stays below.

### Token Deployment Configuration

Default token parameters are in `script/input/token.json`. Deployment fields can be overridden with env vars (see [Step 1](#step-1-deploy-token-on-both-chains)). `tokenAmountToMint` and `tokenAmountToTransfer` are used as defaults by the [Token Operations](#token-operations) scripts:
```json
{
  "name": "BnM Test",
  "symbol": "BnM-T",
  "decimals": 18,
  "maxSupply": 0,
  "preMint": 0,
  "tokenAmountToMint": 1000000000000000000000,
  "tokenAmountToTransfer": 1000000000000000000
}
```

### Advanced Pool Hooks Configuration

Default hooks parameters are in `script/input/advanced-pool-hooks.json`. All fields can be overridden with env vars (see [Deploy Advanced Pool Hooks](#deploy-advanced-pool-hooks)):
```json
{
  "allowlist": [],
  "thresholdAmount": 0,
  "policyEngine": "0x0000000000000000000000000000000000000000",
  "authorizedCallers": []
}
```

### Chain config tooling - discover, add, sync, verify

Tooling under `script/config/` keeps the config files true to the live [CCIP API](https://api.ccip.chain.link/v2). The golden path is the repo `Makefile`: every target is a thin wrapper that sets `FOUNDRY_PROFILE=sync` for you (it enables `ffi` so Foundry can fetch the API via `curl` + `jq`; no RPC URL or keystore needed). The **full command reference** - each target's required args, the raw `forge script` / `bash` command it runs underneath, the `0`/`1`/`2` drift exit-code contract, and the architecture diagrams - is in **[`docs/config-architecture.md`](docs/config-architecture.md)**.

```bash
make discover [FILTER=<term>]                        # list the API catalog vs your local configs
make add-chain CHAIN=<selectorName> SELECTOR=<sel>   # generate config/chains/<selectorName>.json from the API
make sync-preview CHAIN=<name>                        # fetch + log a chain's ccip{}, no write
make sync CHAIN=<name> / make sync-all               # rewrite API-served fields (ccip{} + identity/metadata) from the API
make sync-check [CHAIN=<name>]                        # read-only drift check (CI: bash script/config/sync-check.sh for 0/1/2)
make doctor CHAIN=<name>                              # layered [PASS]/[FAIL]/[WARN]/[SKIP] check of one chain
make fmt-config                                       # restore the canonical config format after a raw forge run
```

`CHAIN=` is the canonical **selectorName** (the file basename). The sync writes **every API-served field** — the `ccip{}` subtree plus the identity/metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`) — leaving every hand-authored key (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`) untouched, and re-canonicalizes as `jq --indent 2 -S`, so a no-drift `make sync` is a **zero-diff** no-op. Every fetch is guarded: the API chainId must equal the config's (`SELECTOR MISMATCH`) and the config `name` must equal the API selectorName (`SELECTOR NAME MISMATCH`); non-EVM chains (e.g. `solana-devnet`) skip the EVM address sync cleanly but still refresh their served identity/metadata. A scheduled workflow (`.github/workflows/config-drift.yml`) runs the drift check weekly: drift fails visibly, an unreachable API only warns.

The tooling is tested twice over: `forge test` pins the API->config transform against a committed real API response (`test/fixtures/ccip-api/`), and `bash script/config/test-tooling.sh` is a re-runnable failure-path suite (unknown chain, overwrite refusal, invalid names, `SELECTOR MISMATCH`, `SELECTOR NAME MISMATCH`, `NOT_FOUND`, API-down, non-EVM skip, the sync-check exit contract, an offline end-to-end sync against a local fixture server, the Makefile golden-path guards, and the canonical-format + zero-diff guarantees).

### Deployed-address registry — `addresses/<chainId>.json` (the default)

After a `--broadcast` deploy, every later script resolves the deployed addresses from the registry automatically — no `export` step. This now holds for **all four artifacts**: `token`, `tokenPool`, `lockBox`, **and** `poolHooks` (the last two previously had to be re-exported by hand). Resolution precedence (highest first), per role:

1. Inline alias — `TOKEN=0x...` / `TOKEN_POOL=0x...` / `LOCK_BOX=0x...` / `POOL_HOOKS=0x...` on the command line
2. Chain-scoped session export — `ETHEREUM_SEPOLIA_TOKEN`, `MANTLE_SEPOLIA_TOKEN_POOL`, `ETHEREUM_SEPOLIA_LOCK_BOX`, ...
3. **Address registry** — `addresses/<chainId>.json` → `active.<role>` (the default path)

The registry is a **schema-v2** file with two sub-stores: `active` (the single per-role pointer `HelperConfig` resolves) and `deployments` (uniquely-named entries whose key carries the pool's type and version — e.g. `BnM-T_BurnMintTokenPool_2.0.0` — so distinct artifacts never collide in storage). One writer owns it: each deploy script makes a single `DeploymentRecorder` call that emits the `script/deployments/**` ledger **and** updates the registry, so the two never drift. `active.<role>` is single-valued: deploy two pools for the same symbol on one chain and the zero-export getters resolve the last one for both tokens (pass the other explicitly). See [config-schema.md](docs/config-schema.md#the-deployed-address-registry---addresseschainidjson-schema-v2) and [deployed-addresses.md](docs/deployed-addresses.md) for the keying table and the two-store model.

The registry also guards against accidental redeploys: while it holds a live address under a `deployments` name, the corresponding deploy script refuses to run and prints the registered address. Set `FORCE_REDEPLOY=true` to deploy a replacement of the *same* name (the old address stays in the append-only `script/deployments/` ledger; the registry itself is gitignored, so it is not in git history). Note `active.tokenPool` is *what this repo last deployed*, not proof of what CCIP routes through — the on-chain TokenAdminRegistry is the authority, and `make doctor` WARNs when they diverge.

### Sharing addresses with your team

Both deployed-address stores are gitignored in this template. When you **fork it into your own project**, you
MAY un-gitignore them to share addresses with colleagues and CI. The two stores warrant different advice — see
[deployed-addresses.md](docs/deployed-addresses.md) for the full two-store model.

- **Registry (`addresses/<chainId>.json`) — recommended for teams.** It holds public addresses only, no
  secrets. Track it and every colleague plus CI resolves the same addresses on clone, with zero `export`.
- **History (`script/deployments/`) — optional.** Be honest about what it is: it is **write-only** (nothing in
  this repo reads it), and it grows one file per deploy forever. Foundry's own `broadcast/` directory already
  records every deploy with richer detail (and is itself gitignored, `.gitignore:8`). Track `script/deployments/`
  only if you specifically want an in-repo, human-readable deploy log.

**Guardrails (mandatory if you track the registry):**

1. **Never commit local/anvil chains.** Keep an explicit ignore for `addresses/31337.json` (and any other
   local chain id).
2. **The test suite writes real `addresses/<chainId>.json` files for scratch chain ids** (e.g. `16602`, and
   the `9000000xx` throwaways). Today `.gitignore` hides them. If you un-ignore the registry, add explicit
   ignores for those scratch ids, or a stray test artifact gets committed. This is real: a leftover scratch
   registry file once bricked the local test suite while `git status` stayed clean.
3. **`active` is not authority.** It records what this repo deployed most recently, not what is wired. The
   on-chain **TokenAdminRegistry** is the source of truth. Run `make doctor CHAIN=<name>` (in CI too) — it
   reconciles the registry pool against the wired pool and WARNs on divergence.
4. **Review registry diffs like config changes.** Put `addresses/` under CODEOWNERS, and gate mainnet
   chain-id files behind stricter approval.
5. **Do this in a single-deployment project**, not a shared template clone where many developers push
   disposable fixtures.

Do **not** claim git gives an audit trail for the registry (it is gitignored), and do not tell people to trust
the file over the on-chain TokenAdminRegistry.

### Session exports — `export VAR=0x...` (overrides)

These are **not** stored in `.env` and are now **optional**: the registry covers the default flow. Use an export (or the chain-agnostic `TOKEN` / `TOKEN_POOL` inline aliases, see [CLI inline vars](#cli-inline-vars----varvalue-forge-script-)) when you want to target a *different* contract than the registered one — e.g. an older deployment or a contract deployed outside this repo. Session exports last for the current terminal — values can always be recovered from `addresses/<chainId>.json` or `script/deployments/`.

> **Note:** Do not add these to `.env`. An env var always **beats** the registry, so a stale `.env` value would silently target the wrong contract after a redeployment.

**Token addresses** — override after [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains):

| Variable | Chain |
|---|---|
| `ETHEREUM_SEPOLIA_TOKEN` | Ethereum Sepolia |
| `MANTLE_SEPOLIA_TOKEN` | Mantle Sepolia |

**Non-EVM destination token addresses** — set before running [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes) when targeting a non-EVM chain. These are base58-encoded addresses, not `0x`-prefixed:

| Variable | Chain |
|---|---|
| `SOLANA_DEVNET_TOKEN` | Solana Devnet |

**Token pool addresses** — override after [Step 2: Deploy Token Pools](#step-2-deploy-token-pools-on-both-chains):

| Variable | Chain |
|---|---|
| `ETHEREUM_SEPOLIA_TOKEN_POOL` | Ethereum Sepolia |
| `MANTLE_SEPOLIA_TOKEN_POOL` | Mantle Sepolia |

**Non-EVM destination token pool addresses** — set before running [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes) when targeting a non-EVM chain. These are base58-encoded addresses, not `0x`-prefixed:

| Variable | Chain |
|---|---|
| `SOLANA_DEVNET_TOKEN_POOL` | Solana Devnet |

### CLI inline vars — `VAR=value forge script ...`

Prepended directly to a single `forge script` command. They apply to that one invocation only and do not affect the shell environment. Each script section documents its own inline vars in full — this table is an index.

> **Note:** Do not add these to `.env`. The same stale-value problem applies: scripts check for zero/empty values to trigger fallback behavior, and a value sourced from `.env` would silently suppress that.

| Variable | Documented in | Config file default |
|---|---|---|
| `TOKEN_NAME`, `TOKEN_SYMBOL`, `TOKEN_DECIMALS`, `TOKEN_MAX_SUPPLY`, `TOKEN_PRE_MINT`, `TOKEN_PRE_MINT_RECIPIENT`, `CCIP_ADMIN_ADDRESS` | [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains) | `script/input/token.json` |
| `ROLES_RECIPIENT` | [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains) | |
| `TOKEN` | Chain-agnostic inline alias for `{CHAIN}_TOKEN`. Accepted by all scripts that resolve a deployed token address. Takes priority over the session export. | |
| `TOKEN_POOL` | Chain-agnostic inline alias for `{CHAIN}_TOKEN_POOL`. Accepted by all scripts that resolve a deployed pool address. Takes priority over the session export. | |
| `DEST_TOKEN_POOL` | Destination-chain pool alias used by `ApplyChainUpdates`. Takes priority over `{DEST_CHAIN}_TOKEN_POOL`. | |
| `DEST_TOKEN` | Destination-chain token alias used by `ApplyChainUpdates`. Takes priority over `{DEST_CHAIN}_TOKEN`. | |
| `POOL_HOOKS` | [Burn & Mint Pool](#burn--mint-pool), [Lock & Release Pool](#lock--release-pool), [Manage Allowlist](#manage-allowlist), [Manage Authorized Callers](#manage-authorized-callers) | |
| `LOCK_BOX` | [Lock & Release Pool](#lock--release-pool), [Deposit to LockBox](#deposit-to-lockbox), [Withdraw from LockBox](#withdraw-from-lockbox), [Manage Authorized Callers](#manage-authorized-callers) | |
| `DECIMALS` | [Burn & Mint Pool](#burn--mint-pool), [Lock & Release Pool](#lock--release-pool) | |
| `AUTHORIZED_CALLERS` | [Lock & Release Pool](#lock--release-pool), [Deploy Advanced Pool Hooks](#deploy-advanced-pool-hooks) | `script/input/advanced-pool-hooks.json` (deploy only) |
| `CCIP_ADMIN_ADDRESS` | [Step 3: Claim Admin](#step-3-claim-admin-on-both-chains) | |
| `DEST_CHAIN` | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Remote Pools](#manage-remote-pools), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config), [Manage Token Transfer Fee Config](#manage-token-transfer-fee-config) | |
| `OUTBOUND_RATE_LIMIT_CAPACITY`, `OUTBOUND_RATE_LIMIT_RATE`, `OUTBOUND_RATE_LIMIT_ENABLED` | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config) | |
| `INBOUND_RATE_LIMIT_CAPACITY`, `INBOUND_RATE_LIMIT_RATE`, `INBOUND_RATE_LIMIT_ENABLED` | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config) | |
| `FAST_FINALITY` | [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config) | |
| `AMOUNT` | [Mint Tokens](#mint-tokens), [Deposit to LockBox](#deposit-to-lockbox), [Withdraw from LockBox](#withdraw-from-lockbox) | `script/input/token.json` |
| `MINT_RECEIVER` | [Mint Tokens](#mint-tokens) | |
| `RECIPIENT` | [Withdraw from LockBox](#withdraw-from-lockbox), [Withdraw Fee Tokens](#withdraw-fee-tokens) | |
| `FEE_TOKENS` | [Get Fee Token Balances](#get-fee-token-balances), [Withdraw Fee Tokens](#withdraw-fee-tokens) | |
| `ROUTER`, `RATE_LIMIT_ADMIN`, `FEE_ADMIN` | [Manage Dynamic Config](#manage-dynamic-config) | |
| `BLOCK_DEPTH`, `WAIT_FOR_SAFE` | [Manage Finality Config](#manage-finality-config) | |
| `REMOTE_POOL_ADDRESS` | [Manage Remote Pools](#manage-remote-pools) | |
| `ALLOWLIST`, `THRESHOLD_AMOUNT`, `POLICY_ENGINE` | [Deploy Advanced Pool Hooks](#deploy-advanced-pool-hooks) | `script/input/advanced-pool-hooks.json` |
| `NEW_HOOK` | [Connect Advanced Pool Hooks to a Token Pool](#connect-advanced-pool-hooks-to-a-token-pool) | |
| `ENTITY_TYPE` | [Transfer Ownership](#transfer-ownership) | |
| `ADDRESS` | [Transfer Ownership](#transfer-ownership) | |
| `NEW_OWNER` | [Transfer Ownership](#transfer-ownership) | |
| `NEW_ADMIN` | [Transfer Token Admin Role](#transfer-token-admin-role) | |
| `ADD_ADDRESSES`, `REMOVE_ADDRESSES` | [Manage Allowlist](#manage-allowlist), [Manage Authorized Callers](#manage-authorized-callers) | |
| `CHECK_ADDRESS` | [Manage Allowlist](#manage-allowlist) | |
| `DEST_GAS_OVERHEAD`, `DEST_BYTES_OVERHEAD`, `FINALITY_FEE_USD_CENTS`, `FAST_FINALITY_FEE_USD_CENTS`, `FINALITY_TRANSFER_FEE_BPS`, `FAST_FINALITY_TRANSFER_FEE_BPS`, `DISABLE` | [Manage Token Transfer Fee Config](#manage-token-transfer-fee-config) | |

## Testing

Run the test suite with:

```bash
forge test
```

No configuration is needed: the fork tests default to public Ethereum Sepolia RPC endpoints (trying several in order, so a single unavailable provider does not fail the suite). To use a private or paid endpoint instead, set `ETHEREUM_SEPOLIA_RPC_URL` (the same variable used by the deployment scripts):

```bash
ETHEREUM_SEPOLIA_RPC_URL=<your-sepolia-rpc-url> forge test
```

The fork tests deploy the token and pool fixtures by running the repo's own deploy scripts, so they exercise the same code paths as the commands documented above.
