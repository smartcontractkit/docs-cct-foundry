---
type: reference
---

# Token operations

> A deploy records the token in your project store automatically; after any later change, reconcile it
> against live with `make doctor CHAIN=<chain>`: see
> [Applying config and reconciling with doctor](../config-architecture.md#applying-config-and-reconciling-with-doctor).

Deploy a cross-chain token and mint its supply. The deploy scripts under `script/deploy/` and the
`script/operations/MintTokens.s.sol` operation. Primitive pages:
[`DeployToken`](../primitives/deploy/DeployToken.md), [`MintTokens`](../primitives/operations/MintTokens.md).

## Deploy a token

Configure token parameters in `script/input/token.json` (see [Config and project-store
schema](../config-schema.md)), or override any field with an environment variable.

| Env var                    | Default (from `token.json`)           |
| -------------------------- | ------------------------------------- |
| `TOKEN_NAME`               | `.name`                               |
| `TOKEN_SYMBOL`             | `.symbol`                             |
| `TOKEN_DECIMALS`           | `.decimals`                           |
| `TOKEN_MAX_SUPPLY`         | `.maxSupply`                          |
| `TOKEN_PRE_MINT`           | `.preMint`                            |
| `TOKEN_PRE_MINT_RECIPIENT` | broadcaster (if `TOKEN_PRE_MINT` > 0) |
| `CCIP_ADMIN_ADDRESS`       | `msg.sender` (broadcaster)            |

Set `ROLES_RECIPIENT` to grant mint and burn roles to a specific address (defaults to the deployer).

Golden path (resolves the RPC from the chain file's `rpcEnv` and the signer from `KEYSTORE_NAME`;
`VERIFY=1` source-verifies on the explorer):

```bash
make deploy-token CHAIN=ethereum-testnet-sepolia VERIFY=1
make deploy-token CHAIN=ethereum-testnet-sepolia-mantle-1 VERIFY=1
```

Raw `forge script` (the escape hatch):

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

`--verify` requires `ETHERSCAN_API_KEY`. A single key covers every Etherscan v2 chain. Chains whose
explorer is not in the Etherscan family take extra verifier flags; see [Verifying deployed
contracts](verification.md).

### Where the address goes

After each deployment the token address is saved to a local `history/` ledger file:

```
history/tokens/{selectorName}/{timestamp}-{SYMBOL}-Token.json
```

The file uses the env var name as the key (for example `ETHEREUM_SEPOLIA_TOKEN`), so you can copy the
key and value straight into an `export`. The `history/` directory is gitignored, local to each user.

A broadcast deploy also records the address in the project store (the `addresses{}` subtree of
`project/<selectorName>.json`), so later scripts resolve the token automatically with no `export`. See
[The store model](../concepts/store-model.md) and [Deployed addresses](../deployed-addresses.md).

Re-running the deploy on the same chain is refused while the registry holds a live address. Set
`FORCE_REDEPLOY=true` to deploy a replacement.

To override the registry address for one session:

```bash
# Option A: export for the session (persists across all commands in the current terminal)
export ETHEREUM_SEPOLIA_TOKEN=0x...
export MANTLE_SEPOLIA_TOKEN=0x...

# Option B: inline alias per command (applies to that one command only)
TOKEN=0x... forge script script/setup/ClaimAdmin.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
```

## Mint tokens

```bash
forge script \
  script/operations/MintTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

Set `AMOUNT` to override the amount to mint (defaults to `tokenAmountToMint` from
`script/input/token.json`). Set `MINT_RECEIVER` to mint to a different address (defaults to the EOA
broadcasting the transaction).
