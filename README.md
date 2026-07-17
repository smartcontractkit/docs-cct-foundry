# CCIP Cross-Chain Token Deployment and Registration Scripts

> **NOTE:** This repository represents an educational example to use a Chainlink system, product, or service and is provided to demonstrate how to interact with Chainlink’s systems, products, and services to integrate them into your own. This template is provided “AS IS” and “AS AVAILABLE” without warranties of any kind, it has not been audited, and it may be missing key checks or error handling to make the usage of the system, product or service more clear. Do not use the code in this example in a production environment without completing your own audits and application of best practices. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outputs that are generated due to errors in code.

Foundry scripts for deploying and managing cross-chain tokens using Chainlink CCIP.

## Prerequisites

Everything a fresh machine needs, in one place:

| Tool                                                                                 | Needed for                                                                                                                | Check                            |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) | building, testing, and every deploy/config script                                                                         | `forge --version`                |
| Node.js + npm                                                                        | installing the Solidity dependencies (`npm install`)                                                                      | `npm --version`                  |
| `make`                                                                               | the golden-path targets in the `Makefile` (preinstalled on macOS/Linux; on Windows use WSL)                               | `make --version`                 |
| `bash`                                                                               | the thin wrapper scripts under `script/config/`                                                                           | `bash --version`                 |
| `curl` + `jq`                                                                        | **only** the chain-config sync tooling (fetching the [CCIP API](https://api.ccip.chain.link/v2)) — deploys don't use them | `curl --version`, `jq --version` |

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

| Env var                    | Default (from `token.json`)           |
| -------------------------- | ------------------------------------- |
| `TOKEN_NAME`               | `.name`                               |
| `TOKEN_SYMBOL`             | `.symbol`                             |
| `TOKEN_DECIMALS`           | `.decimals`                           |
| `TOKEN_MAX_SUPPLY`         | `.maxSupply`                          |
| `TOKEN_PRE_MINT`           | `.preMint`                            |
| `TOKEN_PRE_MINT_RECIPIENT` | broadcaster (if `TOKEN_PRE_MINT` > 0) |
| `CCIP_ADMIN_ADDRESS`       | `msg.sender` (broadcaster)            |

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

> **Note:** `--verify` requires `ETHERSCAN_API_KEY` to be set (see [Prerequisites](#prerequisites)). A single key covers every Etherscan v2 chain. Chains whose explorer is not in the Etherscan family take extra verifier flags; see [Verifying Deployed Contracts](#verifying-deployed-contracts).

Optional: Set `ROLES_RECIPIENT` to grant mint/burn roles to a specific address (defaults to the deployer).

After each deployment, the token address is automatically saved to:

```
history/tokens/{selectorName}/{timestamp}-{SYMBOL}-Token.json
```

The file uses the env var name as the key (e.g. `ETHEREUM_SEPOLIA_TOKEN`). If you need to retrieve the deployed address later, open the file — the key is the env var name and the value is the address, so you can copy both directly into an `export` command. The `history/` directory is ignored by `.gitignore` — files are local to each user.

A broadcast deploy also records the address in the [project store](#project-store--projectselectornamejson-the-default) (the `addresses{}` subtree of `project/<selectorName>.json`), so **subsequent scripts resolve the token automatically — no `export` needed**. Re-running the deploy on the same chain is refused while the registry holds a live address (set `FORCE_REDEPLOY=true` to deploy a replacement).

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
history/token-pools/{selectorName}/{timestamp}-{SYMBOL}-BurnMintTokenPool.json
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

A broadcast deploy records the pool (and lockbox) address in the [project store](#project-store--projectselectornamejson-the-default), so **subsequent scripts resolve it automatically — no `export` needed** (the LockRelease pool deploy also resolves `LOCK_BOX` from the registry). To override the registry address for a session, choose one approach:

```bash
# Option A: export for the session (persists across all commands in the current terminal)
export ETHEREUM_SEPOLIA_TOKEN_POOL=0x...
export MANTLE_SEPOLIA_TOKEN_POOL=0x...

# Option B: inline alias per command (no export needed; applies to that one command only)
TOKEN_POOL=0x... forge script script/setup/SetPool.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
```

Each deployment is automatically saved:

- ERC20LockBox → `history/lock-boxes/{selectorName}/{timestamp}-{SYMBOL}-LockBox.json` — keys: `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`
- LockReleaseTokenPool → `history/token-pools/{selectorName}/{timestamp}-{SYMBOL}-LockReleaseTokenPool.json` — keys: `{CHAIN_NAME_IDENTIFIER}_TOKEN_POOL`, `LOCK_BOX`, `{CHAIN_NAME_IDENTIFIER}_TOKEN`

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

> **Dry run first:** omit `--broadcast` from any command in this step to simulate the apply — the script runs against the fork and prints exactly what it would do, without sending a transaction. Add `--broadcast` back once the output looks right.

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

Rate limits resolve per direction through a two-rung ladder, matching the repo's `inline > env > registry` idiom:

1. **Rate-limit env vars set** — the env values win, exactly as documented in the table below. This is the explicit override path (for example, an incident-response throttle). If the local chain config declares a diverging `lanes{}` policy for the destination, the script prints a one-line notice naming both values, and the closing output prints the exact `make add-lane` command to bring the declaration in line — `make doctor` FAILs until the two agree. An apply never writes `lanes{}` back: the declaration is owner intent, reconciled through a reviewed edit.
2. **Env vars unset** — the buckets come from the declared `lanes{}` entry in the local project store `project/<local>.json` (matched by the remote's config name, falling back to `remoteSelector` equality): `capacity`/`rate` drive the outbound bucket (enabled when either is non-zero), and the optional `inbound{capacity,rate}` block drives the inbound bucket. An absent `inbound{}` block keeps the default: disabled.

With neither env vars nor a `lanes{}` entry, rate limiting stays disabled (the historical default) and the console says so. The golden path is declare once, apply from the declaration: `make add-lane` (see [Chain config tooling](#chain-config-tooling---discover-add-sync-verify)), then run the script with no rate-limit env vars.

To enable rate limits via the env override, pass the capacity and rate — `isEnabled` is automatically set to `true` when either value is provided:

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

| Env var                        | Required | Description                                                                                         |
| ------------------------------ | -------- | --------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`                   | Yes      | Destination chain name (e.g. `MANTLE_SEPOLIA`)                                                      |
| `TOKEN_POOL`                   | No       | Inline alias for the source chain pool address. Takes priority over `{CHAIN}_TOKEN_POOL`.           |
| `DEST_TOKEN_POOL`              | No       | Inline alias for the destination chain pool address. Takes priority over `{DEST_CHAIN}_TOKEN_POOL`. |
| `DEST_TOKEN`                   | No       | Inline alias for the destination chain token address. Takes priority over `{DEST_CHAIN}_TOKEN`.     |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No       | Token bucket capacity for outbound transfers                                                        |
| `OUTBOUND_RATE_LIMIT_RATE`     | No       | Token bucket refill rate (tokens/second) for outbound transfers                                     |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)  |
| `INBOUND_RATE_LIMIT_CAPACITY`  | No       | Token bucket capacity for inbound transfers                                                         |
| `INBOUND_RATE_LIMIT_RATE`      | No       | Token bucket refill rate (tokens/second) for inbound transfers                                      |
| `INBOUND_RATE_LIMIT_ENABLED`   | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)  |

> **Note:** `ApplyChainUpdates` only configures the **standard finality** rate limit bucket. To configure the fast finality bucket, run `UpdateRateLimiters` with `FAST_FINALITY=true` after the lane is set up.

#### Declare vs apply: argument name mapping

`make add-lane` (which declares the policy into the local project store `project/<local>.json`) and the apply scripts (`ApplyChainUpdates`, `UpdateRateLimiters`) name the same rate-limit values differently. When translating a declared lane into an env-override apply, map the arguments as follows:

| `make add-lane` argument | Apply-script env var           |
| ------------------------ | ------------------------------ |
| `REMOTE`                 | `DEST_CHAIN`                   |
| `CAPACITY`               | `OUTBOUND_RATE_LIMIT_CAPACITY` |
| `RATE`                   | `OUTBOUND_RATE_LIMIT_RATE`     |
| `INBOUND_CAPACITY`       | `INBOUND_RATE_LIMIT_CAPACITY`  |
| `INBOUND_RATE`           | `INBOUND_RATE_LIMIT_RATE`      |

`LOCAL` names the **source** chain — the chain whose pool is being configured. The apply scripts infer the source chain from the `--rpc-url` you pass (its `block.chainid`), so there is no `LOCAL` env var: point `--rpc-url` at the source chain's RPC.

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

## Verifying Deployed Contracts

Source-verify every deployed contract on the chain's block explorer; a deploy is not done until the explorer shows verified source. There are two ways in, and the fast path is one flag.

### Fastest: verify as part of the deploy

Add `--verify` (plus the per-chain verifier flags, explained below) to the deploy command. On an Etherscan-family chain that is the whole story:

```bash
forge script script/deploy/DeployToken.s.sol \
  --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" --account "$KEYSTORE_NAME" --broadcast \
  --verify --retries 10 --delay 10
```

That works on Sepolia and Mantle Sepolia with just `ETHERSCAN_API_KEY` set (forge reads it from the env and derives the explorer from `--rpc-url`). For the other chains, one helper fills in the right flags so you do not have to remember which backend a chain uses:

```bash
VERIFIER_FLAGS=$(bash script/config/verify-args.sh ink-testnet-sepolia) &&
forge script script/deploy/DeployToken.s.sol \
  --rpc-url "$INK_SEPOLIA_RPC_URL" --account "$KEYSTORE_NAME" --broadcast \
  --verify $VERIFIER_FLAGS --retries 10 --delay 10
```

`verify-args.sh <chain>` prints the flags for that chain (nothing for Etherscan-family, `--verifier blockscout --verifier-url <url>` for Ink/Plume, `--verifier sourcify` for 0G), so the same command line works for every chain. Composing it into a variable first means a mistyped chain name stops the run before it broadcasts. Leave `$VERIFIER_FLAGS` unquoted: it is a list of flags (empty for Etherscan-family), not one argument.

Confirm it worked by opening the address on the explorer (the `#code` tab shows verified source); the [backend table below](#verifier-backend-per-chain) links a verified example per chain.

### Verify a contract you already deployed

Use the wrapper. It takes the chain, the address, and the contract identifier (`<file>:<ContractName>`), and handles the backend, the retries, and the constructor arguments for you. Verifying the bundled token deployed to Ink:

```bash
bash script/config/verify-contract.sh \
  ink-testnet-sepolia \
  0xYourTokenAddress \
  node_modules/@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol:CrossChainToken
```

`make verify CHAIN=ink-testnet-sepolia ADDRESS=0xYourTokenAddress CONTRACT=node_modules/@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol:CrossChainToken` is the same thing. The address of any past deploy is in that deploy's `broadcast/**/run-latest.json`.

With no fourth argument the wrapper passes `--guess-constructor-args`, so forge reads the constructor arguments from the on-chain creation code (no need to know the constructor shape). To supply them yourself instead, pass an ABI-encoded fourth argument, for example `"$(cast abi-encode 'constructor(...)' ...)"` matching the deployed contract's constructor.

If you would rather run `forge` directly, the wrapper is doing this (compose-first so a wrong chain name aborts before submitting):

```bash
VERIFIER_FLAGS=$(bash script/config/verify-args.sh <chain>) &&
forge verify-contract --chain <chainId> $VERIFIER_FLAGS \
  --watch --retries 10 --delay 10 \
  --guess-constructor-args --rpc-url "$<rpcEnv>" \
  <address> <file>:<ContractName>
```

Swap `--guess-constructor-args --rpc-url ...` for `--constructor-args $(cast abi-encode ...)` to pass the arguments yourself.

### How a chain picks its backend

The backend is data, not code: an optional `verifier{type,url}` block in `config/chains/<selectorName>.json`, where `type` is `etherscan`, `blockscout`, or `sourcify`. No block means the Etherscan family, which forge resolves from the chain id (one `ETHERSCAN_API_KEY` covers all of them); for a chain Etherscan v2 does not serve, forge warns and falls back to Sourcify, its keyless default. Blockscout chains name their instance's `url` (usually `<explorerUrl>/api`); Sourcify chains just set `type`. Nothing per-chain goes in `foundry.toml`, so adding a chain is one `config/chains` edit, and `make doctor CHAIN=<name>` checks the block (an unknown `type` or a `blockscout` block with no `url` FAILs by name).

### Verifier backend per chain

| Chain (selectorName)                | Chain id   | Backend                                                               | Verified example                                                                                                    |
| ----------------------------------- | ---------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `ethereum-testnet-sepolia`          | `11155111` | Etherscan v2 (no `verifier{}` block)                                  | [CrossChainToken](https://sepolia.etherscan.io/address/0x4FE0A569671278D3c2e69025d3B3321F440E517F#code)              |
| `ethereum-testnet-sepolia-mantle-1` | `5003`     | Etherscan v2 (no `verifier{}` block)                                  | [CrossChainToken](https://sepolia.mantlescan.xyz/address/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610#code)            |
| `ink-testnet-sepolia`               | `763373`   | Blockscout (`https://explorer-sepolia.inkonchain.com/api`)            | [CrossChainToken](https://explorer-sepolia.inkonchain.com/address/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610?tab=contract) |
| `plume-testnet-sepolia`             | `98867`    | Blockscout (`https://testnet-explorer.plume.org/api`)                 | pending (the Plume faucet requires a browser check to fund a deployer)                                               |
| `0g-testnet-galileo-1`              | `16602`    | Sourcify (its custom explorer exposes no forge-compatible verify API) | [CrossChainToken](https://repo.sourcify.dev/16602/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610)                        |
| `solana-devnet`                     | non-EVM    | none (no forge verification path)                                     | n/a                                                                                                                  |

Sourcify serves all five EVM chains, so it is both `0g-testnet-galileo-1`'s primary backend and the fallback forge uses when Etherscan v2 does not cover a chain.

### If verification fails or looks odd

- `contract does not exist` / not-yet-on-the-explorer right after a deploy is explorer indexer lag: the explorer has not imported the deployment tx yet. The retry flags cure it (`--watch` polls the status endpoint; `--retries 10 --delay 10` outlasts the lag, versus forge's 5/5 default). Waiting for block confirmations does not help, the tx is already on chain.
- `already verified` is a success, not an error, so re-running is always safe. Etherscan v2 also matches identical bytecode across chains, so an unmodified artifact can come back already-verified without a real submission; that still counts as verified.
- `Local bytecode doesn't match on-chain bytecode` is the real failure to act on: the source or compiler settings differ from what was deployed. Wrong constructor arguments do not cause a bad record, because Etherscan v2 and Blockscout read the true arguments from the on-chain creation code; they cause this bytecode mismatch or nothing.

### Proxies

For a UUPS/ERC1967 proxy deployment, verify **both** the implementation and the proxy, then link the proxy to its implementation on the explorer so the proxy's read/write tabs expose the implementation ABI.

### Deterministic deployment is a non-goal

The repo does not use deterministic deployment (CREATE2 / CreateX): it conflicts with the address-registry and redeploy-guard model, where the registry records what was actually deployed per chain and the guard refuses a duplicate. Addresses are recorded, not derived.

## Adding a New Chain

Supporting a new chain is a **config edit, not a code change** — three commands generate and verify `config/chains/<name>.json` from the live [CCIP API](https://api.ccip.chain.link/v2) (needs only `curl` + `jq` from the [Prerequisites](#prerequisites) — no RPC URL, no keystore, no API key):

```bash
make discover FILTER=base            # 1. find the chain in the API catalog, note its NAME + SELECTOR
make add-chain CHAIN=ethereum-testnet-sepolia-base-1 SELECTOR=10344971235874465080   # 2. generate from the API
make doctor CHAIN=ethereum-testnet-sepolia-base-1   # 3. layered verification — re-run until green
```

`CHAIN` is the chain's **canonical CCIP selectorName** as shown by `make discover` (the API/registry name — e.g. `ethereum-testnet-sepolia-base-1`, not a bespoke `base-sepolia`); it becomes the file name `config/chains/<CHAIN>.json` and is validated against the API. `SELECTOR` is the **explicit identity key**, also from `make discover` — every fetch cross-checks both: a valid-but-wrong selector fails loudly as `SELECTOR MISMATCH`, and a non-canonical name as `SELECTOR NAME MISMATCH`, instead of silently writing another chain's contracts. New chains are **discovered automatically** from `config/chains/` — `HelperConfig` scans the directory, so no Solidity edit is needed anywhere. For a newly added chain the `chainNameIdentifier` (and hence the `rpcEnv` and the `<ID>_TOKEN`/`<ID>_TOKEN_POOL` override prefix) is **derived from the selectorName** as UPPER_SNAKE — so it may differ in style from the six bundled chains' curated short forms (e.g. `AVALANCHE_TESTNET_FUJI`, not `AVALANCHE_FUJI`); `add-chain` **prints the exact `chainNameIdentifier` and `rpcEnv` names it generated** so you never have to guess (or open the JSON) which env var to export. `add-chain` prints your next steps: add the chain's RPC env var to `.env`, review the generated defaults in the config file, wire a lane with `make add-lane`, and re-run the doctor until it reports 0 FAIL. Deploying your token and pool there is the golden path's [Step 1](#step-1-deploy-token-on-both-chains) / [Step 2](#step-2-deploy-token-pools-on-both-chains). Then declare the lane policy with `make add-lane LOCAL=<name> REMOTE=<remote> CAPACITY=<wei> RATE=<wei> BOTH=1`, apply it on-chain via [Step 5](#step-5-apply-chain-updates-configure-cross-chain-routes), and re-run `make doctor` — its lanes rung reconciles the declared policy against the pool. To retire a lane, `make remove-lane LOCAL=<name> REMOTE=<remote> [BOTH=1]` removes the declaration; that is a separate step from the on-chain removal, done with [`RemoveChain`](#remove-a-remote-chain) (whole-chain teardown, every version) or [`RemoveRemotePool`](#remove-a-remote-pool) (a single pool, 1.5.1+), and between the two `make doctor` WARNs that the on-chain lane is not declared.

Full details: [Configuration](#configuration) overview, the per-field [`docs/config-schema.md`](docs/config-schema.md), and the command + architecture reference [`docs/config-architecture.md`](docs/config-architecture.md).

### Which command when

| I want to...                                                                 | Run                                                                                            |
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

`doctor` and `sync-check` layer rather than overlap: `doctor` is the deep single-chain health check for a human (schema, identity, drift, RPC, on-chain code, registry warnings, mesh reciprocity, on-chain lane reconciliation, and declared-`roles{}` authority reconciliation), while `sync-check` is the fleet-wide drift verdict for routine use and CI.

## Ownership Management (Optional)

The following scripts are not required for the core deployment flow but are useful when handing off control to a multisig or a different EOA after initial setup. All token ownership scripts auto-detect the correct ownership pattern — no configuration needed.

### Transfer Ownership

Initiates an ownership transfer for a token, token pool, pool hooks, or lockbox. Use `ENTITY_TYPE` to specify which entity to transfer, and `ADDRESS` to specify the contract address. If `ENTITY_TYPE` is omitted, the contract is treated as a generic `IOwnable` — the same path used for `tokenPool`, `poolHooks`, and `lockBox`.

For token transfers, the script auto-detects the token type and calls the appropriate function:

| Detection                            | Token type                                 | Transfer action                             | Accept required?                                                |
| ------------------------------------ | ------------------------------------------ | ------------------------------------------- | --------------------------------------------------------------- |
| `pendingDefaultAdmin()` succeeds     | CrossChainToken                            | `beginDefaultAdminTransfer`                 | Yes — run `AcceptOwnership`                                     |
| `pendingOwner()` + `owner()` succeed | OZ `Ownable2Step`                          | `transferOwnership`                         | Yes — run `AcceptOwnership`                                     |
| `owner()` only (no `pendingOwner()`) | `ConfirmedOwner` or plain `Ownable`        | `transferOwnership`                         | Yes for `ConfirmedOwner`; plain `Ownable` transfers immediately |
| Neither                              | `BurnMintERC20` v1 (plain `AccessControl`) | `grantRole` + `revokeRole` (atomic, 1-step) | No                                                              |

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

| Env var      | Required | Description                                                               |
| ------------ | -------- | ------------------------------------------------------------------------- |
| `FEE_TOKENS` | Yes      | CSV or JSON array of ERC20 token addresses to withdraw                    |
| `RECIPIENT`  | No       | Address to receive the withdrawn fee tokens (defaults to the broadcaster) |

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

| Env var            | Required | Description                                                                                                                             |
| ------------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `ROUTER`           | No       | The CCIP router address to set on the pool (default: current on-chain value)                                                            |
| `RATE_LIMIT_ADMIN` | No       | Rate limit admin address (default: current on-chain value, then broadcaster)                                                            |
| `FEE_ADMIN`        | No       | Fee admin address (default: current on-chain value, then broadcaster). Set to `address(0)` to restrict fee withdrawal to the owner only |

### Manage Finality Config

> **Note:** Requires TokenPool v2.0 or later. The finality config controls which fast finality modes are accepted for cross-chain transfers. Setting it to `WAIT_FOR_FINALITY` (no env vars, no declaration — the default) disables fast finality transfers. The golden path is to declare the policy in `poolPolicy.finality` in `project/<local>.json` and run the script with no finality env vars — the declaration drives the apply, and the doctor reconciles it (see [`docs/config-schema.md`](docs/config-schema.md#the-poolpolicy-block---pool-scoped-policy)).

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

# Apply the declared poolPolicy.finality (or reset to default finality when nothing is declared):
forge script \
  script/configure/finality-config/SetFinalityConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

The applied value resolves through the standard ladder: env (`WAIT_FOR_SAFE`/`BLOCK_DEPTH`, either present — an explicit `false`/`0` still counts) > declared `poolPolicy.finality` ({`blockDepth`, `waitForSafe`}; an empty block `{}` declares the WAIT_FOR_FINALITY default) > the WAIT_FOR_FINALITY reset. An env override that diverges from (or is missing in) the declaration prints a divergence notice plus a hand-edit hint, and `make doctor` FAILs until reconciled — applies never write `poolPolicy{}` back.

When `DEST_CHAIN` is provided, the script logs the current rate limits before applying any changes, and the updated state after. Each direction is shown independently: the **fast finality bucket** is displayed for directions where it is enabled; the **standard finality bucket** (fallback) is displayed for directions where it is not.

| Env var                        | Required | Description                                                                                                                                                                 |
| ------------------------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BLOCK_DEPTH`                  | No       | Number of block confirmations for fast finality (1–65535). Can be combined with `WAIT_FOR_SAFE` to allow both modes simultaneously. Omit both to reset to default finality. |
| `WAIT_FOR_SAFE`                | No       | Set to `true` to use the `safe` head for fast finality. Can be combined with `BLOCK_DEPTH` to allow both modes simultaneously.                                              |
| `DEST_CHAIN`                   | No       | Remote chain whose lane is queried/updated (e.g. `MANTLE_SEPOLIA`). Required when any rate limit var is set; if omitted, the rate limiter section is skipped entirely       |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | No       | uint128, outbound token bucket capacity (fast finality bucket)                                                                                                              |
| `OUTBOUND_RATE_LIMIT_RATE`     | No       | uint128, outbound token bucket refill rate (tokens/second)                                                                                                                  |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set)                                                                      |
| `INBOUND_RATE_LIMIT_CAPACITY`  | No       | uint128, inbound token bucket capacity (fast finality bucket)                                                                                                               |
| `INBOUND_RATE_LIMIT_RATE`      | No       | uint128, inbound token bucket refill rate (tokens/second)                                                                                                                   |
| `INBOUND_RATE_LIMIT_ENABLED`   | No       | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when `CAPACITY` or `RATE` are set)                                                                      |

### Manage LockRelease Liquidity (v1.x pools)

> **Applies to LockRelease pools on contract versions 1.5.0, 1.5.1, and 1.6.1 only.** These versions hold the locked liquidity on the pool itself and manage it through a **rebalancer**: the pool owner appoints a rebalancer, and only that rebalancer may add or remove liquidity. **On LockRelease pool version 2.0.0 the pool holds no liquidity** — an external lock box does, so use [Deposit to LockBox](#deposit-to-lockbox) and [Withdraw from LockBox](#withdraw-from-lockbox) instead. Burn & Mint pools have no liquidity to manage; they mint and burn.

The rebalancer model has three roles:

- **`setRebalancer`** — the pool **owner** appoints the rebalancer.
- **`provideLiquidity`** — the **rebalancer** adds liquidity. The pool pulls the tokens with `transferFrom`, so the token is approved to the pool first and then the liquidity is provided, in one step.
- **`withdrawLiquidity`** — the **rebalancer** removes liquidity, which is transferred back to it. The pool reverts `InsufficientLiquidity` if its balance is below the requested amount.

Each script resolves the pool from the address registry (or the `TOKEN_POOL` / `{CHAIN}_TOKEN_POOL` alias) and the token from the pool's `getToken()`. The write scripts refuse, with a clear message, before broadcasting when the pool is the wrong type (not LockRelease) or the wrong version (2.0.0, which points you at the lock box), or when the broadcaster is not the pool's rebalancer.

#### View the rebalancer

```bash
forge script script/configure/liquidity/GetRebalancer.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

This read-only script degrades gracefully: on a 2.0.0 LockRelease pool it prints the lock box pointer instead of a rebalancer, and on a non-LockRelease pool it explains that only LockRelease pools have a rebalancer.

#### Set the rebalancer

Broadcast as the pool **owner**:

```bash
REBALANCER=0xYourRebalancerAddress \
  forge script \
  script/configure/liquidity/SetRebalancer.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

#### Provide liquidity

Broadcast as the pool **rebalancer**. `AMOUNT` is in the token's smallest unit (wei):

```bash
AMOUNT=1000000000000000000 \
  forge script \
  script/configure/liquidity/ProvideLiquidity.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

#### Withdraw liquidity

Broadcast as the pool **rebalancer**:

```bash
AMOUNT=1000000000000000000 \
  forge script \
  script/configure/liquidity/WithdrawLiquidity.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var      | Script                                  | Required | Description                                                               |
| ------------ | --------------------------------------- | -------- | ------------------------------------------------------------------------- |
| `REBALANCER` | `SetRebalancer`                         | Yes      | Address to appoint as the pool's rebalancer.                              |
| `AMOUNT`     | `ProvideLiquidity`, `WithdrawLiquidity` | Yes      | Amount of liquidity to add or remove, in the token's smallest unit (wei). |

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

Drops a single remote pool from a chain that stays supported. This is a 1.5.1+ operation; on a 1.5.0 pool it refuses and points at "Remove a Remote Chain" below, since 1.5.0 holds one remote pool per chain (there is no standalone pool removal).

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

##### Remove a Remote Chain

Tears down the whole lane: fully unsupports a remote chain on the source pool (removes the selector and deletes its remote-chain config), so neither direction accepts messages afterward. Use this to retire a lane, not to swap a pool. Works on every pool version (1.5.0 through 2.0.0) — the script dispatches on the pool's on-chain version.

> **Warning:** All inflight transactions on this lane will be rejected after removal. Ensure there are no inflight messages to or from this chain before proceeding. See [`docs/pool-versions.md`](docs/pool-versions.md#removing-a-lane-or-a-pool) for the live-lane drain sequence and the config that survives removal.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  forge script \
  script/configure/remote-chains/RemoveChain.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

### Deploy Advanced Pool Hooks

Use this script for enhanced security features like allowlists, CCV management, policy engine integration, and threshold-based validation.

Configure defaults in `script/input/advanced-pool-hooks.json` (see the [Configuration](#configuration) section), or override any field with environment variables:

| Env var              | Type              | Default (from `advanced-pool-hooks.json`) |
| -------------------- | ----------------- | ----------------------------------------- |
| `ALLOWLIST`          | CSV or JSON array | `.allowlist`                              |
| `AUTHORIZED_CALLERS` | CSV or JSON array | `.authorizedCallers`                      |
| `THRESHOLD_AMOUNT`   | uint256           | `.thresholdAmount`                        |
| `POLICY_ENGINE`      | address           | `.policyEngine`                           |

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
history/advanced-pool-hooks/{selectorName}/{timestamp}-AdvancedPoolHooks.json
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

The golden path for v2 lanes is to declare the policy in the local chain config and apply from the declaration: with no rate-limit env vars, a direction resolves from the `lanes{}` entry in `project/<local>.json` — the standard bucket from `capacity`/`rate` (plus the optional `inbound{}` block), the fast finality bucket (`FAST_FINALITY=true`, 2.0.0 pools) from `v2.fastFinality.outbound` / `v2.fastFinality.inbound`. Env vars remain the explicit override for incident response: they win as-is, and when they disagree with (or are missing from) the declaration, the script prints a divergence notice plus a hand-edit hint with the applied values, and `make doctor` FAILs until the declaration is reconciled. Applies never write `lanes{}` back. See [`docs/config-schema.md`](docs/config-schema.md).

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

| Env var                        | Required                                          | Description                                                                                                   |
| ------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`                   | Yes                                               | Remote chain whose lane is being updated                                                                      |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | To update outbound (unless declared in `lanes{}`) | Token bucket capacity for outbound transfers                                                                  |
| `OUTBOUND_RATE_LIMIT_RATE`     | To update outbound                                | Token bucket refill rate (tokens/second) for outbound transfers                                               |
| `OUTBOUND_RATE_LIMIT_ENABLED`  | No                                                | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)            |
| `INBOUND_RATE_LIMIT_CAPACITY`  | To update inbound (unless declared in `lanes{}`)  | Token bucket capacity for inbound transfers                                                                   |
| `INBOUND_RATE_LIMIT_RATE`      | To update inbound                                 | Token bucket refill rate (tokens/second) for inbound transfers                                                |
| `INBOUND_RATE_LIMIT_ENABLED`   | No                                                | Override `isEnabled` explicitly (`true`/`false`; defaults to `true` when CAPACITY or RATE are set)            |
| `FAST_FINALITY`                | No                                                | `true` to update the fast finality bucket instead of the standard finality bucket (v2 only, default: `false`) |

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

All fee config env vars are optional. Each field resolves independently: an env var wins when set; an unset field takes the declared `lanes.<remote>.v2.feeConfig.<field>` from `project/<local>.json` when the block declares it; otherwise it keeps the current on-chain value. The golden path for v2 lanes is to declare the whole fee config in `v2.feeConfig` and run the script with no fee env vars — the declaration drives the apply. Env vars remain the explicit override for incident response: a value that disagrees with the declaration is applied as-is with a per-field divergence notice plus a hand-edit hint, and `make doctor` FAILs until the declaration is reconciled (applies never write `lanes{}` back). When setting a fee config for the first time with no declaration and no env vars, unset fields default to `0`.

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

| Env var                          | Required | Description                                                                                                                                                                    |
| -------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DEST_CHAIN`                     | Yes      | Remote chain to configure fees for                                                                                                                                             |
| `DEST_GAS_OVERHEAD`              | No       | Gas overhead charged on the destination chain (must be > 0; defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                    |
| `DEST_BYTES_OVERHEAD`            | No       | Data availability bytes overhead (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                                              |
| `FINALITY_FEE_USD_CENTS`         | No       | Flat fee in 0.01 USD units for finality transfers (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                             |
| `FAST_FINALITY_FEE_USD_CENTS`    | No       | Flat fee in 0.01 USD units for fast finality transfers (defaults to the declared `v2.feeConfig` value, then the current on-chain value)                                        |
| `FINALITY_TRANSFER_FEE_BPS`      | No       | Fee in basis points deducted from the transferred amount for finality transfers [0–9999] (defaults to the declared `v2.feeConfig` value, then the current on-chain value)      |
| `FAST_FINALITY_TRANSFER_FEE_BPS` | No       | Fee in basis points deducted from the transferred amount for fast finality transfers [0–9999] (defaults to the declared `v2.feeConfig` value, then the current on-chain value) |
| `DISABLE`                        | No       | Set to `true` to disable the fee config for this lane, reverting the OnRamp to FeeQuoter defaults (default: `false`)                                                           |

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

### Manage CCV Config

Token pools v2.0 and later verify cross-chain messages through **CCVs** (Cross-Chain Verifiers), configured per lane on the pool's `AdvancedPoolHooks` contract: a required set of verifiers for each direction (`outboundCCVs` / `inboundCCVs`) plus an optional additional set that applies once a transfer reaches (is at or above) the threshold amount (`thresholdOutboundCCVs` / `thresholdInboundCCVs`). Because the config lives on the hooks contract, these scripts resolve it via `pool.getAdvancedPoolHooks()`. The setter refuses by name with a named require on a pre-2.0.0 pool (the CCV surface is 2.0.0-only) or when no hooks contract is wired; the getter degrades gracefully, printing an informative message instead of reverting.

##### View CCV Config

Reads the per-lane verifier arrays and the pool-global threshold.

```bash
forge script \
  script/configure/ccv/GetCCVConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

##### Set or Update CCV Config

Each verifier array and the threshold resolve independently through the same ladder as the fee and rate-limit scripts: an env var (a comma-separated address list) wins when set; an unset array takes the declared `lanes.<remote>.v2.ccv.<field>` from `project/<local>.json` when the block declares it; otherwise it keeps the current on-chain value. The golden path for v2 lanes is to declare the CCV set in `v2.ccv` (and the threshold in the pool-scoped `poolPolicy.ccvThreshold`) and run the script with no CCV env vars — the declaration drives the apply. **The read-modify-write is important**: `applyCCVConfigUpdates` replaces a lane's whole entry, so the script reads the current on-chain arrays first and overwrites only the arrays you declare — changing `OUTBOUND_CCVS` never wipes your inbound verifiers. Env vars remain the explicit override for incident response: a value that disagrees with the declaration (compared as a set, order-insensitive) is applied as-is with a divergence notice plus a hand-edit hint (the `v2.ccv` block has no `make add-lane` flag — reconcile it with a reviewed hand edit), and `make doctor` FAILs until reconciled (applies never write `lanes{}` back).

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_CCVS=0xVerifierA,0xVerifierB \
  INBOUND_CCVS=0xVerifierC \
  forge script \
  script/configure/ccv/UpdateCCVConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var                   | Required        | Description                                                                                                                                                                                |
| ------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DEST_CHAIN`              | For lane arrays | Remote chain whose CCV set is being configured (omit to set only the pool-global threshold)                                                                                                |
| `OUTBOUND_CCVS`           | No              | Comma-separated required verifier addresses for outgoing messages (defaults to the declared `v2.ccv.outboundCCVs`, then the current on-chain value)                                        |
| `INBOUND_CCVS`            | No              | Comma-separated required verifier addresses for incoming messages (defaults to the declared value, then on-chain)                                                                          |
| `THRESHOLD_OUTBOUND_CCVS` | No              | Additional outbound verifiers required at or above the threshold amount; requires a non-empty outbound base set                                                                            |
| `THRESHOLD_INBOUND_CCVS`  | No              | Additional inbound verifiers required at or above the threshold amount; requires a non-empty inbound base set                                                                              |
| `CCV_THRESHOLD_AMOUNT`    | No              | Pool-global transfer amount at or above which the threshold verifier sets apply (defaults to the declared `poolPolicy.ccvThreshold`, then the current on-chain value; `0` = no threshold) |

## Supported Networks

**EVM chains (source or destination):**

- Ethereum Sepolia (`ETHEREUM_SEPOLIA`)
- Mantle Sepolia (`MANTLE_SEPOLIA`)
- Ink Sepolia (`INK_SEPOLIA`)
- Plume Testnet (`PLUME_TESTNET`)
- 0G Galileo Testnet (`0G_GALILEO_TESTNET` — digit-leading, so its `<ID>_*` override vars cannot live in `.env`; see [`docs/deployed-addresses.md`](docs/deployed-addresses.md))

Any other chain in the CCIP testnet catalog is onboarded as a config edit — see [Adding a New Chain](#adding-a-new-chain).

**Non-EVM chains (destination only):**

> Non-EVM chains can only be used as the **destination** chain in `ApplyChainUpdates` — i.e. to register a non-EVM token pool on an EVM source chain. They cannot be used as source chains in this repo.

- Solana Devnet (`SOLANA_DEVNET`)

## Configuration

The repo keeps its cross-chain state as **data, not code**, in two files per chain (both keyed by the canonical CCIP **selectorName**, e.g. `ethereum-testnet-sepolia`):

- **`config/chains/<selectorName>.json`** holds pure API/chain facts: the API-synced `ccip{}` address block + API-synced identity/metadata (`displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`), the hand-authored keys the API serves nothing for (`chainNameIdentifier`, `rpcEnv`, and the optional `verifier{}` block), and the join keys. **Always git-tracked.** `HelperConfig` reads it through `src/config/ChainConfig.sol` and discovers the chain list by scanning the `config/chains` directory, so adding a chain (or updating a CCIP address) is a **reviewed config edit with zero Solidity changes**.
- **`project/<selectorName>.json`** — the **project store**: three subtrees, one writer each, plus `"schema": 3`. `addresses{}` is the deployed-address registry (`active` role pointers + versioned `deployments`), written on a broadcast by the deploy recorder and by `make adopt-token`; `lanes{}` is owner policy (which remotes this pool connects to, at what outbound rate limits), written by `make add-lane`; `roles{}` is authority, written by `make snapshot-chain`. **Gitignored in this template** (it holds throwaway test addresses; only `project/ethereum-testnet-sepolia.example.json` ships) — a downstream **fork un-gitignores it** to track its own lanes/roles/addresses.

**Multiple token groups (one clone, N tokens).** A clone can manage several independent cross-chain tokens without collision: pass `GROUP=<name>` and that token's state lives under `project/<name>/<selectorName>.json`, its own isolated mesh universe. An unset `GROUP` is the **default** group — the flat `project/<selectorName>.json` — so a single-token user never sets it and sees no change, and a second token added later goes in its own group with zero effect on the first. `make add-lane`, `remove-lane`, `adopt-token`, `snapshot-chain`, `doctor`, and `roles-check` all take `GROUP=` (with `roles-check` the one exception to "unset = default": unset sweeps the default group **and** every other group). The deploys have no make wrapper, so a second token's deploy is the first grouped step — a raw `forge script` that takes `PROJECT_GROUP=<name>` directly (e.g. `PROJECT_GROUP=usdx forge script script/deploy/DeployToken.s.sol ...`, and the pool deploy likewise). `config/chains` and `history/` stay shared (chain facts are per-chain, not per-token). See [`docs/config-schema.md`](docs/config-schema.md#the-project-store---projectselectornamejson).

**One writer per subtree, and two audit surfaces.** In `config/chains`, the CCIP REST API owns every field it serves (via the sync); the hand keys are hand-authored in reviewed PRs; the join keys are guard-validated. Because the file is always git-tracked, a git diff is an unambiguous audit log. In the project store, each subtree has one writer (`RegistryWriter` for `addresses{}`, `make add-lane` for `lanes{}`, `make snapshot-chain` for `roles{}`), each writing only its own subtree so no writer clobbers another. So the audit surface is `config/chains` in the template, and `config/chains` **plus** a tracked `project/` in a fork. The deploy `history/` ledger stays gitignored in both. Environment variables remain **read-only overrides** on top of the registry: an env-driven run resolves the override but never writes the store.

> **Reference docs:** **[`docs/config-schema.md`](docs/config-schema.md)** is the per-field reference for both files (config/chains facts + the project store's `addresses{}`/`lanes{}`/`roles{}` subtrees + the non-EVM shape); **[`docs/config-architecture.md`](docs/config-architecture.md)** is the `make`-command reference plus the layered architecture (brand-colored Mermaid diagrams: layering, sync data-flow, the two-file store model, and the selectorName join); **[`docs/deployed-addresses.md`](docs/deployed-addresses.md)** is the deployed-address loop and the template-vs-fork tracking rule. The operational how-to (discover → add-chain → sync → doctor) stays below.

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
make add-lane LOCAL=<a> REMOTE=<b> CAPACITY=<wei> RATE=<wei> [INBOUND_CAPACITY=<wei> INBOUND_RATE=<wei>] [BOTH=1]  # declare a lanes{} policy entry (inbound pair adds the inbound block; BOTH=1 adds the reciprocal)
make adopt-token CHAIN=<name> TOKEN=<addr> [TOKEN_POOL=<addr>]        # adopt externally deployed contracts into the project store (non-EVM: TOKEN_B58= [POOL_B58=])
make sync-preview CHAIN=<name>                        # fetch + log a chain's ccip{}, no write
make sync CHAIN=<name> / make sync-all               # rewrite API-served fields (ccip{} + identity/metadata) from the API
make sync-check [CHAIN=<name>]                        # read-only drift check (CI: bash script/config/sync-check.sh for 0/1/2)
make snapshot-chain CHAIN=<name>                      # backfill the roles{} authority block FROM chain (only writer of roles{})
make roles-check [CHAIN=<name>]                       # read-only authority reconcile (CI: bash script/config/roles-check.sh for 0/1/2)
make doctor CHAIN=<name>                              # layered [PASS]/[FAIL]/[WARN]/[SKIP] check of one chain (incl. the roles rung)
make fmt-config                                       # restore the canonical config format after a raw forge run
```

`CHAIN=` is the canonical **selectorName** (the file basename). The sync writes **every API-served field** (the `ccip{}` subtree plus the identity/metadata fields `displayName`, `chainFamily`, `environment`, `explorerUrl`, `nativeCurrencySymbol`), leaving the hand-authored keys (`chainNameIdentifier`, `rpcEnv`, the optional `verifier{}` block) untouched, never touching the project store, and re-canonicalizes as `jq --indent 2 -S` (trailing newline), so a no-drift `make sync` is a **zero-diff** no-op. Every fetch is guarded: the API chainId must equal the config's (`SELECTOR MISMATCH`) and the config `name` must equal the API selectorName (`SELECTOR NAME MISMATCH`); non-EVM chains (e.g. `solana-devnet`) skip the EVM address sync cleanly but still refresh their served identity/metadata. A scheduled workflow (`.github/workflows/config-drift.yml`) runs the drift check weekly: drift fails visibly, an unreachable API only warns.

`make adopt-token` brings externally deployed contracts into the project store's `addresses{}` subtree, and it is guarded too: everything is validated on-chain before anything is written (the token's registration path is probed, and a given pool must report a cataloged contract version per [`docs/pool-versions.md`](docs/pool-versions.md) and manage exactly that token). A non-EVM chain uses the base58 path, `make adopt-token CHAIN=<solana-chain> TOKEN_B58=<base58> [POOL_B58=<base58>]`, which feeds `applyChainUpdates` from the store instead of the old env-only path; see [`docs/enabling-existing-token.md`](docs/enabling-existing-token.md).

`make add-lane` is the mirror-image writer for the `lanes{}` subtree: it writes **only** `.lanes` (same preserve-and-replace pattern the sync uses for `.ccip`), copying the remote's `chainSelector` into the entry as `remoteSelector`. It is guarded too: a **duplicate** lane is a logged no-op that leaves the file byte-identical, a **self-lane** (same chain, or two config files sharing one selector) is refused, and a lane to a remote whose **pool is not deployed yet** logs a WARN naming the missing deploy. `make doctor` proves the mesh on top: every lane must resolve to an existing config file with a matching selector, and a **one-sided lane FAILs, naming both chains** (add the reciprocal with `BOTH=1`); lanes to non-EVM chains are exempt from reciprocity (destination-only). With an RPC configured, the doctor's final **lanes rung** reconciles the declared policy against the on-chain pool itself, both directions: a declared value the chain contradicts — the core buckets, declared `inbound{}`/`v2{}` blocks, and the pool-scoped `poolPolicy{}` values — **FAILs naming the exact field** (every drifted field is reported in one run; remediate on-chain or update the declaration), while declared-but-not-applied and on-chain-but-not-declared lanes stay WARNs (see `docs/config-architecture.md`).

The declaration is also **consumed**: [Step 5](#step-5-apply-chain-updates-configure-cross-chain-routes) run with no rate-limit env vars applies the declared `lanes{}` policy directly (declare once, apply from the declaration), while the rate-limit env vars remain the explicit override for incident response. An env-override apply that leaves the declaration missing or diverging prints the exact `make add-lane` command to bring it in line, and the doctor FAILs until it is — applies never write `lanes{}` back.

The tooling is tested twice over: `forge test` pins the API->config transform against a committed real API response (`test/fixtures/ccip-api/`) and proves the `lanes{}` subtree contracts (`test/config/LaneConfig.t.sol`: a lane survives a `ccip` sync, `add-lane` touches no other subtree, a one-sided lane fails the mesh rung from either side; the inbound block is written and nested policy blocks survive rewrites; `test/config/VerifyChainLaneReconcile.t.sol` proves the on-chain lanes rung per state, including the 1.5.0 version-dispatch path and the multi-drift aggregation contract, with `test/config/VerifyChainCCVReconcile.t.sol` and `test/config/VerifyChainFinalityReconcile.t.sol` covering the CCV and poolPolicy reconciles; `test/setup/ApplyChainUpdatesLaneSource.t.sol` proves the env > `lanes{}` rate-limit resolution ladder and the `make add-lane` remediation hint states), and `bash script/config/test-tooling.sh` is a re-runnable failure-path suite (unknown chain, overwrite refusal, invalid names, `SELECTOR MISMATCH`, `SELECTOR NAME MISMATCH`, `NOT_FOUND`, API-down, non-EVM skip, the sync-check exit contract, an offline end-to-end sync against a local fixture server, the Makefile golden-path guards, the add-lane preflights and guards, the mesh-reciprocity doctor verdicts, the canonical-format + zero-diff guarantees, and the manual-plane refusals, where `make sync` refuses a `configSource: "manual"` chain and never touches its addresses, a typo'd marker is refused rather than overwritten, `sync-check` SKIPs it, and a cross-plane `add-lane` is refused naming both chains; `test/config/VerifyChainManualPlane.t.sol` pins the doctor's schema/API/mesh branches for the marker).

### Manual address planes: a non-API deployment per clone

Every `ccip{}` address is normally sourced from the CCIP REST API. To run this repo against a deployment the API does **not** serve (the same real chain selectors and chainIds, but a different Router / RMN proxy / TokenAdminRegistry / RegistryModuleOwnerCustom / FeeQuoter set), declare it in data: **one clone = one address plane.** Hand-edit the existing `config/chains/<selectorName>.json` in a reviewed diff, replace the `ccip{}` block with that plane's addresses, and stamp one optional key:

```jsonc
{
  "name": "ethereum-testnet-sepolia",
  "configSource": "manual", // absent = "api" (the default); "manual" = a reviewed hand edit owns ccip{}
  "ccip": {
    "router": "0x…", // the addresses for THIS plane
    "feeQuoter": "0x…"
    // …
  }
}
```

The marker flips the declared writer of `ccip{}` from the API to your reviewed edit, and every API-coupled tool reacts by name: `make sync` / `sync-all` **REFUSE** to touch the chain (a named SKIP, so the API can never overwrite your addresses back), `make sync-check` **SKIPs** it (the CI drift sweep stays green), and `make doctor`'s API rung is a named **SKIP + one WARN** (an address change on this plane is not API-detectable) while every other rung runs unchanged. With an RPC set, the on-chain rung also logs the FeeQuoter's `typeAndVersion` as a version check. `make add-lane` and the doctor's mesh rung **REFUSE a cross-plane lane** (one API chain plus one manual chain), naming both. Hand-editing `ccip{}` **without** the marker stays loud (doctor DRIFT + red `sync-check` + the next `sync` reverts it); the drift error points you at `configSource: "manual"` when the change is deliberate.

Because the whole plane is a per-clone property (the shared chainIds would otherwise mix planes within one run), keep each plane in its own **git worktree** on your fork, so `config/chains` in each is internally consistent and the plane is a reviewed branch diff:

```bash
# main worktree stays on the API plane; a second worktree carries the manual plane
git worktree add ../cct-manual-plane manual-plane
cd ../cct-manual-plane
# hand-edit config/chains/<selectorName>.json: swap ccip{} + add "configSource": "manual", commit
make doctor CHAIN=<selectorName>        # API rung SKIPs+WARNs; schema/RPC/on-chain/mesh/roles run normally
```

This repo ships **no** address preset for any such plane, because those addresses change on redeploys and no external service tracks them, so the mechanism ships and the data never does. The reviewed branch diff (which addresses were in use, when) is your audit trail. See [`docs/config-schema.md`](docs/config-schema.md#manual-address-planes-configsource-manual).

### Authority durable store — the `roles{}` subtree

Where `ccip{}` is API fact, **`lanes{}` and `roles{}` are the project store's owner-written subtrees**:
`roles{}` is declared authority — who holds every privileged role across the token, its pool, the
TokenAdminRegistry, and (when present) the lockbox and hooks. It is the durable record of _who controls
this deployment_ (git-versioned once a fork tracks `project/`), reconciled against the live chain — the
same declare-once-then-reconcile model as `lanes{}`, with the same one-writer discipline. Full field reference: [`docs/config-schema.md`](docs/config-schema.md#the-roles-subtree---declared-authority-not-api-fact); the operational runbook (mental model, drift decision tree, honest-coverage caveat): [`docs/roles.md`](docs/roles.md).

```bash
make snapshot-chain CHAIN=<name>   # ONLY writer: backfill roles{} FROM chain (opt: TOKEN= TOKEN_POOL= TAR= SCAN_FROM_BLOCK=)
make roles-check CHAIN=<name>      # READ-ONLY reconcile of declared roles{} vs the live chain (never writes)
make doctor CHAIN=<name>           # includes a roles rung that mounts the same reconcile
```

`make snapshot-chain` is the **only** writer (backfill from chain, preserve-and-replace on the `.roles`
subtree only); `make roles-check` and the doctor's roles rung only READ. The check exits `0` clean /
`1` drift (naming the exact field) / `2` RPC unavailable — the `0/1/2` contract lives in
`script/config/roles-check.sh` (CI calls it directly; `make roles-check` is pass/fail only, the same
pattern as `sync-check`). A scheduled non-blocking `roles-check` job in
`.github/workflows/config-drift.yml` surfaces authority drift weekly. The token block **dispatches on a
declared `type`** — `crosschain` / `burnmint` / `factory` / `byo` — because the admin model differs per
template (including `crosschain`'s separate `BURN_MINT_ADMIN_ROLE`, the slot a naive sweep forgets).
Governance-critical single-holder slots are verified by direct getter reads (reliable on any RPC, no
`eth_getLogs`); multi-holder lists carry an honest `complete` marker and a clean check on a `byo` token
does **not** prove its mint/burn rights are safe (see the honest-coverage caveat in `docs/roles.md`).
The `VerifyRoles` reader (`script/governance/VerifyRoles.s.sol`) prints the current holder of every
slot for an at-a-glance audit.

### Project store — `project/<selectorName>.json` (the default)

After a `--broadcast` deploy, every later script resolves the deployed addresses from the registry (the `addresses{}` subtree of the project store) automatically — no `export` step. This holds for **all four artifacts**: `token`, `tokenPool`, `lockBox`, **and** `poolHooks`. Resolution precedence (highest first), per role:

1. Inline alias — `TOKEN=0x...` / `TOKEN_POOL=0x...` / `LOCK_BOX=0x...` / `POOL_HOOKS=0x...` on the command line
2. Chain-scoped session export — `ETHEREUM_SEPOLIA_TOKEN`, `MANTLE_SEPOLIA_TOKEN_POOL`, `ETHEREUM_SEPOLIA_LOCK_BOX`, ...
3. **Registry** — `project/<selectorName>.json` → `addresses.active.<role>` (the default path)

The registry has two sub-stores: `active` (the single per-role pointer `HelperConfig` resolves) and `deployments` (uniquely-named entries whose key carries the pool's type and version — e.g. `BnM-T_BurnMintTokenPool_2.0.0` — so distinct artifacts never collide in storage). Values are strings: EVM hex, or base58 on a non-EVM chain. One writer owns it: each deploy script makes a single `DeploymentRecorder` call that emits the `history/` ledger **and** updates the registry (`writeJson` on `.addresses` only, leaving `lanes{}`/`roles{}` byte-identical), so the two never drift. `active.<role>` is single-valued: deploy two pools for the same symbol on one chain and the zero-export getters resolve the last one for both tokens (put the second token in its own group, or pass the other explicitly — see deployed-addresses.md). See [config-schema.md](docs/config-schema.md#the-addresses-sub-store-the-registry) and [deployed-addresses.md](docs/deployed-addresses.md) for the keying table and the full loop.

The registry also guards against accidental redeploys: while it holds a live address under a `deployments` name, the corresponding deploy script refuses to run and prints the registered address. Set `FORCE_REDEPLOY=true` to deploy a replacement of the _same_ name (the old address stays in the append-only `history/` ledger; in the template the project store is gitignored, so the drop is not in git history — a fork that tracks `project/` sees it in the diff). Note `active.tokenPool` is _what this repo last deployed_, not proof of what CCIP routes through — the on-chain TokenAdminRegistry is the authority, and `make doctor` WARNs when they diverge.

### Sharing addresses with your team

`project/` and `history/` are gitignored in this template. When you **fork it into your own project**, you
SHOULD un-gitignore `project/` to share lanes, roles, and addresses with colleagues and CI — public data
only, never secrets. `history/` is optional. See [deployed-addresses.md](docs/deployed-addresses.md) for the
full model.

- **Project store (`project/<selectorName>.json`) — recommended for teams.** It holds public addresses,
  reviewed lane policy, and reviewed authority — no secrets. Track it and every colleague plus CI resolves
  the same state on clone (zero `export`), and a git diff becomes an audit log for lanes/roles/addresses
  alongside `config/chains`.
- **History (`history/`) — optional.** Be honest about what it is: it is **write-only** (nothing in this
  repo reads it), and it grows one file per deploy forever. Foundry's own `broadcast/` directory already
  records every deploy with richer detail (and is itself gitignored, `.gitignore:8`). Track `history/` only
  if you specifically want an in-repo, human-readable deploy log.

**Guardrails (mandatory if you track the project store):**

1. **Never commit local/anvil or scratch chains.** The template already ignores `project/local-*.json` and
   `project/zz-scratch-*.json`; keep those patterns. The test suite writes real `project/zz-scratch-*.json`
   files, so a missing ignore commits a stray test artifact. This is real: a leftover scratch file once
   bricked the local test suite while `git status` stayed clean.
2. **Never commit secrets.** The store is public data only (addresses + reviewed policy/authority). A
   secret-shaped value (URL / hex private key) in any `project/` file FAILs a lint.
3. **`active` is not authority.** It records what this repo deployed most recently, not what is wired. The
   on-chain **TokenAdminRegistry** is the source of truth. Run `make doctor CHAIN=<name>` (in CI too) — it
   reconciles the registry pool against the wired pool and WARNs on divergence.
4. **Review project-store diffs like config changes.** Put `project/` under CODEOWNERS, and gate mainnet
   files behind stricter approval.
5. **Do this in a single-deployment project**, not a shared template clone where many developers push
   disposable fixtures.

The audit surface is `config/chains` (always tracked) plus a fork's tracked `project/`; do not tell people
to trust the store over the on-chain TokenAdminRegistry.

### Session exports — `export VAR=0x...` (overrides)

These are **not** stored in `.env` and are now **optional**: the registry covers the default flow. Use an export (or the chain-agnostic `TOKEN` / `TOKEN_POOL` inline aliases, see [CLI inline vars](#cli-inline-vars--varvalue-forge-script-)) when you want to target a _different_ contract than the registered one — e.g. an older deployment or a contract deployed outside this repo. Session exports last for the current terminal — values can always be recovered from `project/<selectorName>.json` or the `history/` ledger.

> **Note:** Do not add these to `.env`. An env var always **beats** the registry, so a stale `.env` value would silently target the wrong contract after a redeployment.

**Token addresses** — override after [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains):

| Variable                 | Chain            |
| ------------------------ | ---------------- |
| `ETHEREUM_SEPOLIA_TOKEN` | Ethereum Sepolia |
| `MANTLE_SEPOLIA_TOKEN`   | Mantle Sepolia   |

**Non-EVM destination token addresses** — set before running [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes) when targeting a non-EVM chain. These are base58-encoded addresses, not `0x`-prefixed:

| Variable              | Chain         |
| --------------------- | ------------- |
| `SOLANA_DEVNET_TOKEN` | Solana Devnet |

**Token pool addresses** — override after [Step 2: Deploy Token Pools](#step-2-deploy-token-pools-on-both-chains):

| Variable                      | Chain            |
| ----------------------------- | ---------------- |
| `ETHEREUM_SEPOLIA_TOKEN_POOL` | Ethereum Sepolia |
| `MANTLE_SEPOLIA_TOKEN_POOL`   | Mantle Sepolia   |

**Non-EVM destination token pool addresses** — set before running [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes) when targeting a non-EVM chain. These are base58-encoded addresses, not `0x`-prefixed:

| Variable                   | Chain         |
| -------------------------- | ------------- |
| `SOLANA_DEVNET_TOKEN_POOL` | Solana Devnet |

### CLI inline vars — `VAR=value forge script ...`

Prepended directly to a single `forge script` command. They apply to that one invocation only and do not affect the shell environment. Each script section documents its own inline vars in full — this table is an index.

> **Note:** Do not add these to `.env`. The same stale-value problem applies: scripts check for zero/empty values to trigger fallback behavior, and a value sourced from `.env` would silently suppress that.

| Variable                                                                                                                                                                      | Documented in                                                                                                                                                                                                                                                                                                 | Config file default                                   |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `TOKEN_NAME`, `TOKEN_SYMBOL`, `TOKEN_DECIMALS`, `TOKEN_MAX_SUPPLY`, `TOKEN_PRE_MINT`, `TOKEN_PRE_MINT_RECIPIENT`, `CCIP_ADMIN_ADDRESS`                                        | [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains)                                                                                                                                                                                                                                                   | `script/input/token.json`                             |
| `ROLES_RECIPIENT`                                                                                                                                                             | [Step 1: Deploy Token](#step-1-deploy-token-on-both-chains)                                                                                                                                                                                                                                                   |                                                       |
| `TOKEN`                                                                                                                                                                       | Chain-agnostic inline alias for `{CHAIN}_TOKEN`. Accepted by all scripts that resolve a deployed token address. Takes priority over the session export.                                                                                                                                                       |                                                       |
| `TOKEN_POOL`                                                                                                                                                                  | Chain-agnostic inline alias for `{CHAIN}_TOKEN_POOL`. Accepted by all scripts that resolve a deployed pool address. Takes priority over the session export.                                                                                                                                                   |                                                       |
| `DEST_TOKEN_POOL`                                                                                                                                                             | Destination-chain pool alias used by `ApplyChainUpdates`. Takes priority over `{DEST_CHAIN}_TOKEN_POOL`.                                                                                                                                                                                                      |                                                       |
| `DEST_TOKEN`                                                                                                                                                                  | Destination-chain token alias used by `ApplyChainUpdates`. Takes priority over `{DEST_CHAIN}_TOKEN`.                                                                                                                                                                                                          |                                                       |
| `POOL_HOOKS`                                                                                                                                                                  | [Burn & Mint Pool](#burn--mint-pool), [Lock & Release Pool](#lock--release-pool), [Manage Allowlist](#manage-allowlist), [Manage Authorized Callers](#manage-authorized-callers)                                                                                                                              |                                                       |
| `LOCK_BOX`                                                                                                                                                                    | [Lock & Release Pool](#lock--release-pool), [Deposit to LockBox](#deposit-to-lockbox), [Withdraw from LockBox](#withdraw-from-lockbox), [Manage Authorized Callers](#manage-authorized-callers)                                                                                                               |                                                       |
| `DECIMALS`                                                                                                                                                                    | [Burn & Mint Pool](#burn--mint-pool), [Lock & Release Pool](#lock--release-pool)                                                                                                                                                                                                                              |                                                       |
| `AUTHORIZED_CALLERS`                                                                                                                                                          | [Lock & Release Pool](#lock--release-pool), [Deploy Advanced Pool Hooks](#deploy-advanced-pool-hooks)                                                                                                                                                                                                         | `script/input/advanced-pool-hooks.json` (deploy only) |
| `CCIP_ADMIN_ADDRESS`                                                                                                                                                          | [Step 3: Claim Admin](#step-3-claim-admin-on-both-chains)                                                                                                                                                                                                                                                     |                                                       |
| `DEST_CHAIN`                                                                                                                                                                  | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Remote Pools](#manage-remote-pools), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config), [Manage Token Transfer Fee Config](#manage-token-transfer-fee-config) |                                                       |
| `OUTBOUND_RATE_LIMIT_CAPACITY`, `OUTBOUND_RATE_LIMIT_RATE`, `OUTBOUND_RATE_LIMIT_ENABLED`                                                                                     | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config)                                                                                                                     |                                                       |
| `INBOUND_RATE_LIMIT_CAPACITY`, `INBOUND_RATE_LIMIT_RATE`, `INBOUND_RATE_LIMIT_ENABLED`                                                                                        | [Step 5: Apply Chain Updates](#step-5-apply-chain-updates-configure-cross-chain-routes), [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config)                                                                                                                     |                                                       |
| `FAST_FINALITY`                                                                                                                                                               | [Manage Rate Limiters](#manage-rate-limiters), [Manage Finality Config](#manage-finality-config)                                                                                                                                                                                                              |                                                       |
| `AMOUNT`                                                                                                                                                                      | [Mint Tokens](#mint-tokens), [Deposit to LockBox](#deposit-to-lockbox), [Withdraw from LockBox](#withdraw-from-lockbox)                                                                                                                                                                                       | `script/input/token.json`                             |
| `MINT_RECEIVER`                                                                                                                                                               | [Mint Tokens](#mint-tokens)                                                                                                                                                                                                                                                                                   |                                                       |
| `RECIPIENT`                                                                                                                                                                   | [Withdraw from LockBox](#withdraw-from-lockbox), [Withdraw Fee Tokens](#withdraw-fee-tokens)                                                                                                                                                                                                                  |                                                       |
| `FEE_TOKENS`                                                                                                                                                                  | [Get Fee Token Balances](#get-fee-token-balances), [Withdraw Fee Tokens](#withdraw-fee-tokens)                                                                                                                                                                                                                |                                                       |
| `ROUTER`, `RATE_LIMIT_ADMIN`, `FEE_ADMIN`                                                                                                                                     | [Manage Dynamic Config](#manage-dynamic-config)                                                                                                                                                                                                                                                               |                                                       |
| `BLOCK_DEPTH`, `WAIT_FOR_SAFE`                                                                                                                                                | [Manage Finality Config](#manage-finality-config)                                                                                                                                                                                                                                                             |                                                       |
| `REMOTE_POOL_ADDRESS`                                                                                                                                                         | [Manage Remote Pools](#manage-remote-pools)                                                                                                                                                                                                                                                                   |                                                       |
| `ALLOWLIST`, `THRESHOLD_AMOUNT`, `POLICY_ENGINE`                                                                                                                              | [Deploy Advanced Pool Hooks](#deploy-advanced-pool-hooks)                                                                                                                                                                                                                                                     | `script/input/advanced-pool-hooks.json`               |
| `NEW_HOOK`                                                                                                                                                                    | [Connect Advanced Pool Hooks to a Token Pool](#connect-advanced-pool-hooks-to-a-token-pool)                                                                                                                                                                                                                   |                                                       |
| `ENTITY_TYPE`                                                                                                                                                                 | [Transfer Ownership](#transfer-ownership)                                                                                                                                                                                                                                                                     |                                                       |
| `ADDRESS`                                                                                                                                                                     | [Transfer Ownership](#transfer-ownership)                                                                                                                                                                                                                                                                     |                                                       |
| `NEW_OWNER`                                                                                                                                                                   | [Transfer Ownership](#transfer-ownership)                                                                                                                                                                                                                                                                     |                                                       |
| `NEW_ADMIN`                                                                                                                                                                   | [Transfer Token Admin Role](#transfer-token-admin-role)                                                                                                                                                                                                                                                       |                                                       |
| `ADD_ADDRESSES`, `REMOVE_ADDRESSES`                                                                                                                                           | [Manage Allowlist](#manage-allowlist), [Manage Authorized Callers](#manage-authorized-callers)                                                                                                                                                                                                                |                                                       |
| `CHECK_ADDRESS`                                                                                                                                                               | [Manage Allowlist](#manage-allowlist)                                                                                                                                                                                                                                                                         |                                                       |
| `DEST_GAS_OVERHEAD`, `DEST_BYTES_OVERHEAD`, `FINALITY_FEE_USD_CENTS`, `FAST_FINALITY_FEE_USD_CENTS`, `FINALITY_TRANSFER_FEE_BPS`, `FAST_FINALITY_TRANSFER_FEE_BPS`, `DISABLE` | [Manage Token Transfer Fee Config](#manage-token-transfer-fee-config)                                                                                                                                                                                                                                         |                                                       |

## Testing

### Running the tests

Build and run the Solidity suite with:

```bash
forge build
forge test --ffi
```

`--ffi` enables the few canonical-format tests that cross-check against `jq`; without it those tests skip with a named reason and everything else still runs.

No configuration is needed: the fork tests default to public Ethereum Sepolia RPC endpoints (trying several in order, so a single unavailable provider does not fail the suite). To use a private or paid endpoint instead, set `ETHEREUM_SEPOLIA_RPC_URL` (the same variable used by the deployment scripts):

```bash
ETHEREUM_SEPOLIA_RPC_URL=<your-sepolia-rpc-url> forge test
```

The fork tests deploy the token and pool fixtures by running the repo's own deploy scripts, so they exercise the same code paths as the commands documented above.

The chain-config tooling has its own shell suite, `script/config/test-tooling.sh`, split into three partitions:

```bash
TOOLING_PARTITION=offline bash script/config/test-tooling.sh # no live API needed - the CI-blocking set
TOOLING_PARTITION=live bash script/config/test-tooling.sh    # reaches the real CCIP API - the scheduled set
bash script/config/test-tooling.sh                           # both (the default)
```

The offline partition is genuinely network-free: cases that need API responses are served committed fixtures (`test/fixtures/ccip-api/`) from a local server, so it passes fully airgapped.

The suites write gitignored `zz-scratch-*` fixtures into `config/chains/`, `project/`, and `history/` because discovery is directory-based, so the tooling must be exercised against real files in the scanned directories. A green run cleans up after itself — CI enforces this with an inventory gate (`git status --porcelain --ignored -- config/chains project history` must be empty after `forge test`, whatever the filename). A failed test leaves its own fixtures in place for inspection, until the next run's setup sweep or `make clean-scratch` removes them.

Lint the Solidity sources with:

```bash
forge lint
```
