---
type: index
---

# Gotchas

An austere, one-line registry of known facts that bite integrators, each under a stable anchor other docs
link to.

## Registry

<a id="forking-excludes-chains"></a>
- **The read primitives fork, and forking rules out chains a plain `eth_call` would reach.**
  `AdoptToken.s.sol` and `VerifyChain.s.sol` call `vm.createSelectFork`, so every chain-reading target
  inherits Foundry's fork backend and its `eth_getProof` and EIP-1898 requirements. Chains that serve
  ordinary `eth_call` but not those cannot be read at all. A second, more common failure is that
  `createSelectFork` pins whatever one node called `latest`, and a later request routed to a node a
  moment behind cannot serve that block: `vm.createSelectFork: failed to get account ... HTTP 400
  {"message":"Unknown block","code":26}`. **How badly this bites scales with the chain's block time.**
  Monad produces a block roughly every 0.3s, so a few hundred milliseconds of lag is several blocks
  gone; Sepolia's ~12s blocks absorb the same lag unnoticed. Measured on `make doctor`: monad-testnet
  through a load-balanced gateway failed 9 of 10 runs on a free key and 3 of 10 on a paid one, and
  passed 3 of 3 through the chain's own single-provider RPC - while Sepolia through the same paid
  gateway passed 10 of 10. A paid plan reduces this; it does not remove it. `make probe-chain
  CHAIN=<name>` never pins a block, so backend lag cannot reach it (20 of 20 across both chains). Nothing here calls `getProof` itself, so there is nothing local to switch off.
  `make probe-chain CHAIN=<name>` reads the same wiring over plain JSON-RPC with no fork and answers on
  those chains; it reports rather than verifies, and `doctor` stays the fuller check wherever forking
  works. The same fork dependence is why the Sepolia fork tests flake against public endpoints.

<a id="fork-needs-network-named"></a>
- **A script that forks internally must still be told the endpoint on the CLI.** forge 1.8.x types the
  EVM by execution network and refuses a fork whose family differs:
  ``vm.createSelectFork: cannot create a `monad` fork with an EVM instantiated for `ethereum` ``
  (`crates/evm/core/src/fork/multi.rs`, `require_endpoint_family_match`). A `forge script` with no
  `--rpc-url` boots as generic `ethereum`, so the flag is what names the network. **But it cannot simply
  be passed always:** on an OP-stack chain the same flag makes forge abort inside `op_revm` (measured on
  Base Sepolia: rc=134 with it, VERIFIED without). So it is a fallback, not a default -
  `script/config/forge-fork.sh` runs the script bare and re-runs with `--rpc-url` only on this one
  error, which is what the four forking targets (`doctor`, `adopt-token`, `snapshot-chain`,
  `roles-check.sh`) call. By hand, do the same: run it bare first, and add
  `--rpc-url "$(bash script/config/rpc-url.sh <chain>)"` only if you see this error. Never pass the
  flag empty - the read targets degrade to a clean SKIP without an endpoint, and an empty `--rpc-url`
  turns that into a fork-setup error instead.

<a id="chains-that-cannot-be-forked"></a>
- **A node that rejects the EIP-1898 block-object parameter cannot be forked by forge 1.8.x, on any
  pin, and downgrading is not a supported route.** 1.8.x resolves a fork to one exact block and
  addresses its preflight reads by block hash - `{"blockHash":"0x...","requireCanonical":false}`, from
  `exact_block_id()` in `crates/evm/core/src/fork/resolved.rs` (new in 1.8.x), with the backend then
  anchored on that same hash; 1.7.1 sent a plain number or tag, which is why such a chain worked there.
  Pharos mainnet answers the bare hash but rejects the wrapper with
  `PARAM_VERIFY_ERROR: failed to parse block hash or number`, so `doctor` and every other fork-based
  target fails there permanently. `make probe-chain CHAIN=<name>` is the only reader that works: it
  pins no block, needs the chain's `rpcEnv` set in `.env` like any other target, and reports rather than
  verifies. See [the parameter-form measurements](../decisions/0002-eip-1898-fork-reads.md).

<a id="bash-32-empty-array"></a>
- **On stock macOS an empty array is an "unbound variable".** `/bin/bash` there is 3.2, which under
  `set -u` treats `"${arr[@]}"` on an EMPTY array as unset and aborts; bash 5 and CI's Ubuntu runner
  expand it to nothing. It reached an operator as `make preflight` failing outright with
  `sender_args[@]: unbound variable` while passing everywhere it was tested. Write
  `"${arr[@]+"${arr[@]}"}"` for any array that can legitimately be empty, or mark the line
  `# bash32-ok:` with the reason it cannot be. `test-tooling.sh` sweeps for this statically, because a
  runtime check would pass on CI and on any machine whose PATH `bash` is newer than `/bin/bash`.

<a id="pool-version-pinned"></a>
- **Pool version is pinned to 2.0.0 in the deploy path.** Migration coexistence is not reachable through
  the deploy scripts; the migration guide points at the fixture instead.

<a id="single-valued-active-pointer"></a>
- **The `active.<role>` pointer is single-valued.** On a two-token chain, zero-export resolution returns
  the last-deployed pool for both tokens; storage is collision-free but resolution is not. Thread
  `GROUP=` or an explicit address.

<a id="allowlist-frozen-at-deploy"></a>
- **The allowlist enable-flag is frozen at hooks construction.** Deploy Advanced Pool Hooks with a
  non-empty initial allowlist to keep allowlisting available; an empty initial allowlist turns it off
  permanently. There is no setter to flip it: changing whether allowlisting is on or off means deploying a
  new `AdvancedPoolHooks` and re-pointing the pool at it with `UpdateAdvancedPoolHooks`.

<a id="getexecutionstate-signature-versioned"></a>
- **`getExecutionState` has three version-specific signatures.** v2.0 `getExecutionState(bytes32
  messageId)`; v1.6.x `getExecutionState(uint64 sourceChainSelector, uint64 sequenceNumber)`; v1.5.x
  `EVM2EVMOffRamp.getExecutionState(uint64 sequenceNumber)`. Resolve the OffRamp `typeAndVersion` first; a
  wrong-arity `cast call` decodes garbage.

<a id="enabled-zero-zero-pauses"></a>
- **`isEnabled=true` with `capacity=0, rate=0` PAUSES; `isEnabled=false` with the same numbers REMOVES the
  limit.** Identical numbers, opposite behavior; only the flag differs (v1.6+/v2.0; v1.5.x rejects an
  enabled `rate=0`).

<a id="token-decimals-precision"></a>
- **Cross-chain decimals round down and silently discard dust.** A token can have different decimals per
  chain; a v2 pool rescales on the destination with integer division, so a transfer smaller than
  `10**(srcDec-dstDec)` floors to zero on the destination (burned on source, never minted on dest). The
  pool's declared local decimals must equal the token's decimals at deploy time.

<a id="lane-teardown-edges"></a>
- **Removing a remote pool is not removing a lane, and re-adding a lane reactivates stale config.**
  Removing a remote pool leaves the chain supported with zero pools, so inbound release-or-mint reverts
  with a source-pool error. Chain removal wipes rate-limit config while CCV and fee config persist keyed
  by selector, so re-adding a lane silently reactivates the stale CCV/fee config.

<a id="factory-cannot-deploy-hooks"></a>
- **The factory cannot deploy hooks.** A factory-deployed pool starts with allowlist and CCV off; Advanced
  Pool Hooks must be deployed directly and attached before ownership moves to a Safe.

<a id="two-governance-axes"></a>
- **Pool ownership and the TokenAdminRegistry administrator are two separate authorities.** Pool ownership
  governs config; the registry administrator governs the set-pool cutover, and they can be different
  holders. A timelock owning the pool does not delay-gate a migration cutover unless the registry
  administrator moves under it too; keep the rate-limit admin on the Safe for fast emergency throttles.

<a id="evm-version-push0"></a>
- **A `paris` EVM cannot read a contract built by a current toolchain, and the failure blames the
  contract.** `PUSH0` (`0x5f`) is a shanghai opcode that any recent solc emits, and Foundry's
  `evm_version` configures the local interpreter as well as the compile target, so a paris-configured
  `forge script` halts on `EvmError: NotActivated` before it signs anything (`--skip-simulation` does not
  help: it skips the on-chain simulation, not the script body). Where the call is wrapped in `try/catch`
  the halt is worse than a failure, because it is reported as a missing ABI member: a healthy token gets
  `decimals() not found on token`. This repo therefore targets shanghai and declares the exception per
  chain: the few CCIP networks that never activated PUSH0 carry `"evmVersion": "paris"` in
  `config/chains/<selectorName>.json`. `make add-chain` probes this automatically, and
  `make detect-evm-version CHAIN=<selectorName>` re-checks a chain already in the repo. To probe by
  hand, run `cast call --rpc-url <rpc> --create 0x5f5ff3`, and trust the answer only when both controls
  behave: `--create 0xfe` must error (some nodes swallow invalid opcodes) and `--create 0x60006000f3`
  must return `0x` (otherwise the endpoint is not running `eth_call` at all). Check `eth_chainId`
  matches the chain you meant, because public RPC directories carry chainId collisions.

<a id="a-successful-call-can-still-revert-your-frame"></a>
- **A successful call can still revert your frame.** `try C(a).f() returns (string memory)` routes a
  REVERT to its catch, but the return data is decoded in the CALLER's frame after the call already
  succeeded. An address that answers successfully with bytes that are not a valid ABI encoding
  therefore reverts outside the catch, with no reason string - the operator sees `EvmError: Revert` and
  the message names no read. A codeless address is the easy half (it answers with empty data); an
  address WITH code can answer just as undecodably - a Safe with no fallback handler, an EIP-1167 clone
  over a codeless implementation, a proxy whose catch-all fallback returns rather than reverts - so a
  `code.length` guard covers only half of it. Applies to any dynamic return type: `string`, `bytes`,
  arrays, structs containing them. Use `src/utils/TolerantCall.sol`, which validates offset, length and
  bounds before decoding. `src/roles/RolesProbes.sol` covers value types, but only `_tryUint` and
  `_tryBytes32` are fully safe: `address` and `bool` carry decoder validators that reject a dirty word
  the same way. Find the remaining instances with: rg 'abi.decode' src script | rg -v TolerantCall

_The registry grows as findings graduate from the internal vault under the publication gate._
