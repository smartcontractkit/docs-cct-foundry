---
type: reference
---

# Verifying deployed contracts

Source-verify every deployed contract on the chain's block explorer; a deploy is not done until the
explorer shows verified source. There are two ways in, and the fast path is one flag. Backed by
`script/config/verify-args.sh` and `script/config/verify-contract.sh`, wrapped by `make verify-args` and
`make verify`.

## Fastest: verify as part of the deploy

Add `--verify` (plus the per-chain verifier flags, explained below) to the deploy command. On an
Etherscan-family chain that is the whole story:

```bash
forge script script/deploy/DeployToken.s.sol \
  --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" --account "$KEYSTORE_NAME" --broadcast \
  --verify --retries 10 --delay 10
```

That works on Sepolia and Mantle Sepolia with just `ETHERSCAN_API_KEY` set (forge reads it from the env
and derives the explorer from `--rpc-url`). For the other chains, one helper fills in the right flags so
you do not have to remember which backend a chain uses:

```bash
VERIFIER_FLAGS=$(bash script/config/verify-args.sh ink-testnet-sepolia) &&
forge script script/deploy/DeployToken.s.sol \
  --rpc-url "$INK_SEPOLIA_RPC_URL" --account "$KEYSTORE_NAME" --broadcast \
  --verify $VERIFIER_FLAGS --retries 10 --delay 10
```

`verify-args.sh <chain>` prints the flags for that chain (nothing for Etherscan-family, `--verifier
blockscout --verifier-url <url>` for Ink/Plume, `--verifier sourcify` for 0G), so the same command line
works for every chain. Composing it into a variable first means a mistyped chain name stops the run
before it broadcasts. Leave `$VERIFIER_FLAGS` unquoted: it is a list of flags (empty for Etherscan-
family), not one argument.

Confirm it worked by opening the address on the explorer (the `#code` tab shows verified source); the
backend table below links a verified example per chain.

## Verify a contract you already deployed

Use the wrapper. It takes the chain, the address, and the contract identifier (`<file>:<ContractName>`),
and handles the backend, the retries, and the constructor arguments for you. Verifying the bundled token
deployed to Ink:

```bash
bash script/config/verify-contract.sh \
  ink-testnet-sepolia \
  0xYourTokenAddress \
  node_modules/@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol:CrossChainToken
```

`make verify CHAIN=ink-testnet-sepolia ADDRESS=0xYourTokenAddress CONTRACT=node_modules/@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol:CrossChainToken`
is the same thing. The address of any past deploy is in that deploy's `broadcast/**/run-latest.json`.

With no fourth argument the wrapper passes `--guess-constructor-args`, so forge reads the constructor
arguments from the on-chain creation code (no need to know the constructor shape). To supply them
yourself instead, pass an ABI-encoded fourth argument, for example `"$(cast abi-encode 'constructor(...)'
...)"` matching the deployed contract's constructor.

If you would rather run `forge` directly, the wrapper is doing this (compose-first so a wrong chain name
aborts before submitting):

```bash
VERIFIER_FLAGS=$(bash script/config/verify-args.sh <chain>) &&
forge verify-contract --chain <chainId> $VERIFIER_FLAGS \
  --watch --retries 10 --delay 10 \
  --guess-constructor-args --rpc-url "$<rpcEnv>" \
  <address> <file>:<ContractName>
```

Swap `--guess-constructor-args --rpc-url ...` for `--constructor-args $(cast abi-encode ...)` to pass the
arguments yourself.

## How a chain picks its backend

The backend is data, not code: an optional `verifier{type,url}` block in
`config/chains/<selectorName>.json`, where `type` is `etherscan`, `blockscout`, or `sourcify`. No block
means the Etherscan family, which forge resolves from the chain id (one `ETHERSCAN_API_KEY` covers all of
them); for a chain Etherscan v2 does not serve, forge warns and falls back to Sourcify, its keyless
default. Blockscout chains name their instance's `url` (usually `<explorerUrl>/api`); Sourcify chains
Set `type`. Nothing per-chain goes in `foundry.toml`, so adding a chain is one `config/chains` edit,
and `make doctor CHAIN=<name>` checks the block (an unknown `type` or a `blockscout` block with no `url`
FAILs by name).

## Verifier backend per chain

| Chain (selectorName)                | Chain id   | Backend                                                               | Verified example                                                                                                          |
| ----------------------------------- | ---------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `ethereum-testnet-sepolia`          | `11155111` | Etherscan v2 (no `verifier{}` block)                                  | [CrossChainToken](https://sepolia.etherscan.io/address/0x4FE0A569671278D3c2e69025d3B3321F440E517F#code)                    |
| `ethereum-testnet-sepolia-mantle-1` | `5003`     | Etherscan v2 (no `verifier{}` block)                                  | [CrossChainToken](https://sepolia.mantlescan.xyz/address/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610#code)                  |
| `ink-testnet-sepolia`               | `763373`   | Blockscout (`https://explorer-sepolia.inkonchain.com/api`)            | [CrossChainToken](https://explorer-sepolia.inkonchain.com/address/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610?tab=contract) |
| `plume-testnet-sepolia`             | `98867`    | Blockscout (`https://testnet-explorer.plume.org/api`)                 | pending (the Plume faucet requires a browser check to fund a deployer)                                                     |
| `0g-testnet-galileo-1`              | `16602`    | Sourcify (its custom explorer exposes no forge-compatible verify API) | [CrossChainToken](https://repo.sourcify.dev/16602/0xfC3BdAbD8a6A73B40010350E2a61716a21c87610)                              |
| `solana-devnet`                     | non-EVM    | none (no forge verification path)                                     | n/a                                                                                                                       |

Sourcify serves all five EVM chains, so it is both `0g-testnet-galileo-1`'s primary backend and the
fallback forge uses when Etherscan v2 does not cover a chain.

## If verification fails or looks odd

- `contract does not exist` or not-yet-on-the-explorer right after a deploy is explorer indexer lag: the
  explorer has not imported the deployment tx yet. The retry flags cure it (`--watch` polls the status
  endpoint; `--retries 10 --delay 10` outlasts the lag, versus forge's 5/5 default). Waiting for block
  confirmations does not help; the tx is already on chain.
- `already verified` is a success, not an error, so re-running is always safe. Etherscan v2 also matches
  identical bytecode across chains, so an unmodified artifact can come back already-verified without a
  real submission; that still counts as verified.
- `Local bytecode doesn't match on-chain bytecode` is the real failure to act on: the source or compiler
  settings differ from what was deployed. Wrong constructor arguments do not cause a bad record, because
  Etherscan v2 and Blockscout read the true arguments from the on-chain creation code; they cause this
  bytecode mismatch or nothing.

## Proxies

For a UUPS/ERC1967 proxy deployment, verify both the implementation and the proxy, then link the proxy to
its implementation on the explorer so the proxy's read/write tabs expose the implementation ABI.

## Deterministic deployment is a non-goal

The repo does not use deterministic deployment (CREATE2 / CreateX): it conflicts with the
address-registry and redeploy-guard model, where the registry records what was actually deployed per
chain and the guard refuses a duplicate. Addresses are recorded, not derived.
