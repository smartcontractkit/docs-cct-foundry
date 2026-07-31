---
name: ApplyChainUpdates
script: script/setup/ApplyChainUpdates.s.sol
group: token-admin-registry
type: reference
modes: [eoa, safe]
read_only: false
writes_onchain: true
destructive: true
---

# ApplyChainUpdates

Configures cross-chain lanes on the source TokenPool by calling applyChainUpdates.

**When to use.** Configure a remote chain on a token pool: the remote pool addresses, the remote token address, and both rate limiter configs.

## Inputs

| Env var | Description |
| --- | --- |
| `DEST_CHAIN` | See the script header. |
| `DEST_CHAIN_FAMILY` | See the script header. |
| `DEST_CHAIN_SELECTOR` | See the script header. |
| `DEST_TOKEN` | See the script header. |
| `DEST_TOKEN_POOL` | See the script header. |
| `INBOUND_RATE_LIMIT_CAPACITY` | uint128 token-bucket capacity (inbound). Same all-or-nothing rule per direction. |
| `INBOUND_RATE_LIMIT_ENABLED` | true/false; defaults to true when CAPACITY or RATE are set. false stands alone as a disable. |
| `INBOUND_RATE_LIMIT_RATE` | uint128 token-bucket refill rate (inbound). |
| `OUTBOUND_RATE_LIMIT_CAPACITY` | uint128 token-bucket capacity. Per direction the inputs are all-or-nothing: an enabled bucket needs CAPACITY and RATE together, and a partial set is refused naming the missing variable. |
| `OUTBOUND_RATE_LIMIT_ENABLED` | true/false; defaults to true when CAPACITY or RATE are set. false stands alone as a disable. |
| `OUTBOUND_RATE_LIMIT_RATE` | uint128 token-bucket refill rate. An enabled bucket needs CAPACITY and RATE together. |
| `VIA_JSON_FILE` | See the script header. |

## Preconditions

The executing account owns the pool. Every remote address is already chain-family encoded (EVM: abi.encode(address); SVM: raw 32 bytes).

## Postconditions

The chain's entry on the pool matches the payload exactly.

## Known failure modes

REPLACE, NOT MERGE: re-applying an already-configured chain removes its whole entry first, including every registered remote pool and both rate limiter configs, so anything the payload omits is lost. Mid-migration that drops the old remote pool a lane still needs (in-flight messages then fail InvalidSourcePoolAddress) or un-throttles a lane throttled on purpose. Repeating a selector inside one payload reverts NonExistentChain, because the first removal already took it out.

## Reference

- Script: [`script/setup/ApplyChainUpdates.s.sol`](../../../script/setup/ApplyChainUpdates.s.sol)
- Modes: eoa, safe
- Read-only: false | Writes on-chain: true | Destructive: true

_This page is generated from the script by `script/docs/gen-primitives.mjs`. Edit the script's
`@notice` for the description, or `docs/primitives/_meta.json` for the authored context; do not edit
this file by hand._
