---
type: decision
---

# 2. Read chains that reject EIP-1898 without a fork, rather than pinning forge back

## Context

Every read primitive here reaches the chain through `vm.createSelectFork`. Moving the toolchain from
forge 1.7.1 to 1.8.1 made two chains unreadable that had worked before, and the second of them cannot
be fixed from this repo.

forge 1.8.x resolves a fork to one exact block and addresses its preflight reads by block hash.
`exact_block_id()` in `crates/evm/core/src/fork/resolved.rs` - a file that does not exist in 1.7.1 -
returns `BlockId::from((hash, Some(false)))`, which serialises to the EIP-1898 object form, and the
fork backend is then anchored on that same hash. 1.7.1 sent a plain block number or tag.

A node is free to implement only the plain form. Pharos mainnet does, and the difference is exactly
the wrapper: measured against `https://rpc.pharos.xyz` with a real hash from `eth_getBlockByNumber`,

| `eth_getBalance` block parameter | result |
| --- | --- |
| `{"blockHash":"0x...","requireCanonical":false}` (what 1.8.x sends) | `PARAM_VERIFY_ERROR: failed to parse block hash or number` |
| `{"blockHash":"0x..."}` | same error |
| `"0x..."` (the same hash, as a plain string) | accepted |

The same three forks were run under both releases minutes apart: 1.7.1 passed, 1.8.1 failed. So the
regression is real, it is in the toolchain rather than in this repo, and it has no local fix.

## Decision

Stay on current forge, and read such chains with `make probe-chain`, which issues `vm.rpc` calls
directly and pins no block. `doctor` and the other fork-based targets stay as they are and simply do
not work on those chains.

`probe-chain` reports; it does not verify. It answers "is this endpoint usable, and is the CCIP core
wired" - not the layered checks `doctor` performs. On a chain in this class, that is the ceiling.

## Rationale

**Pinning forge back to 1.7.1 would trade one broken chain for a frozen toolchain.** It would also
have kept hiding the problem: two field reports of exactly these failures could not be reproduced here
while the pin was in place, which is how they came to look like bad reports.

**The hash-pinning is correct behaviour, not a bug to wait out.** Resolving a fork to an exact block
is what stops a long-running fork silently reading state from a different block. Upstream carries a
unit test asserting the EIP-1898 serialisation, so it is deliberate and will not be reverted.

**Nothing in this repo calls `eth_getProof` or builds a block parameter**, so there is no local switch
to flip. The only alternatives are the node accepting the object form, or the fork-based targets
moving onto raw reads - a change to how every read primitive reaches the chain, tracked separately.

## Consequences

- A chain in this class is not `doctor`-verifiable on the supported toolchain. `probe-chain` gives a
  report, and the operator accepts that ceiling or reads the chain with other tooling.
- The claim is endpoint-specific and dated: it was measured on 2026-09-08. A node that later accepts
  EIP-1898 makes this record obsolete for that chain, and the three-row table above is the test.
- `probe-chain` issues one HTTP request per read and retries transport failures, because on exactly
  the shaky endpoints it exists for it was otherwise the more fragile reader.
