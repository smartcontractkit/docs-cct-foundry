---
type: reference
---

# Prerequisites, layered by what you are doing

The core layer is enough to deploy, wire, and configure. The two deltas below are added only when you
also send and monitor transfers, or run against a live testnet.

## Core (deploy and configure)

- **Foundry** (`forge`, `cast`) - the build and scripting toolchain.
- **Node + npm** - installs the Solidity dependencies (`npm ci`) and the dev tooling.
- **make**, **bash**, **curl**, **jq** - the golden-path targets and the config/API sync.
- A **Foundry keystore** account for signing (`cast wallet import <name>`, used as `--account <name>`).
  Never a private key in `.env`. See [the signing ADR](../decisions/0001-keystore-signing.md).

This layer never needs `ccip-cli`.

## To send and monitor a transfer

- Install **`@chainlink/ccip-cli`** (globally or via `npx`), minimum **>= 1.10**.
- `ccip-cli` is **NOT a build or deploy dependency**. The toolkit deploys, wires, and configures with
  Foundry and make alone. `ccip-cli` exists only so you can test your token transfers end to end (send,
  then track and diagnose via the API). A deploy-and-configure-only user never installs it.
- **`unset CCIP_API_URL`** before using the CLI: a value for that variable (which a sourced `.env` may
  carry) maps to a non-existent yargs option and crashes the strict parser. This is a one-line caution
  beside the CLI, not a broad warning; it mainly bites users who set that variable deliberately.

## To run on a live testnet

- **Per-chain RPC variable.** The environment variable name for a chain's RPC equals the `rpcEnv` field in
  its `config/chains/<name>.json`. Adding a chain means exporting `<THAT_RPCENV>=<url>` (for example
  `ETHEREUM_SEPOLIA_RPC_URL=...`). The `make deploy-*` targets read `rpcEnv` and resolve the RPC for you;
  a bare `forge script` needs it exported.
- **Funding.** Each chain needs native gas for the signer, plus LINK or native for CCIP fees. Fund before
  you send. Funding is the real-world blocker a clean-room checklist omits: a live send hits it
  immediately (a missing per-chain RPC var and a chain's native-fee floor are the usual first failures).
  Use each chain's faucet for testnet gas.
