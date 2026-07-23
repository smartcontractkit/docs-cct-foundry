---
type: guide
---

# Expand the mesh: add a chain to an existing mesh

Add a chain to an N-chain token mesh so every existing chain transfers to and from the new one, and the
new one to and from all of them. This is a wiring task on top of the existing per-operation scripts, not
new code. The deploy and lane primitives are unchanged; the work is applying them in a full fan-out and
then proving the fan-out is complete.

## The recipe

Run these for the new chain against every existing peer.

1. Deploy and register the token on the new chain. Deploy the token and its pool, then register it and
   point the `TokenAdminRegistry` at the pool, exactly as for a first chain: steps 1 to 4 of the
   [greenfield deploy](../workflows/greenfield-deploy.md) (`DeployToken`, `DeployBurnMintTokenPool`,
   `ClaimAndAcceptAdmin`, `SetPool`). Nothing about the mesh changes these steps.
2. Declare the lanes both ways. For each existing peer, declare the reciprocal lane in one command:

   ```bash
   # Repeat once per existing peer; BOTH=1 writes the reciprocal entry on the peer's file too.
   make add-lane LOCAL=<new-chain> REMOTE=<peer> CAPACITY=<wei> RATE=<wei> BOTH=1
   ```

   `BOTH=1` writes both `lanes.<peer>` on the new chain and `lanes.<new-chain>` on the peer, so the
   declared mesh stays reciprocal. See [Lanes and remote pools](../operations/lanes-and-remotes.md) for
   the lane policy fields and rate-limit options.

3. Wire the pools on-chain both ways. Declaration is policy; the pools are still unwired until you apply
   it. Run [`ApplyChainUpdates`](../operations/lanes-and-remotes.md#apply-chain-updates) on the new pool
   once per peer (so the new pool lists every peer as a remote), and on each peer's pool once for the new
   chain (so every peer lists the new pool). The apply reads the remote pool address from the registry, so
   each side must already know the other's pool address before you apply.
4. Verify the whole fan-out. Run `make doctor CHAIN=<name>` on every chain, then run the remote-pool
   cross-check in [Prove the mesh is complete](#prove-the-mesh-is-complete) for each directed lane. A green
   doctor alone does not prove the mesh transfers.

## The fan-out is O(peers)

Adding one chain to an existing N-chain mesh touches:

- **N + 1 pools.** The new pool gains N remotes (one per existing peer), and each of the N existing pools
  gains one remote (the new pool).
- **2N directed lane configs.** N outbound from the new pool to each peer, plus N from each peer back to
  the new pool.

So the per-chain-addition cost grows with the size of the mesh. Budget the apply transactions and the
verification loop for `2N` lanes, not a fixed two.

## Prove the mesh is complete

`make doctor` at 0 FAIL on every chain does not prove the mesh transfers. The doctor checks two things,
and neither reads the remote pool address that a release validates against:

- The **mesh rung** checks declaration reciprocity only: for each declared lane it confirms the remote's
  `config/chains/<remote>.json` exists and its stored `remoteSelector` matches, and that the reciprocal
  `lanes{}` entry is declared on the remote's project store. It never reads the remote chain on-chain.
- The **lanes rung** checks the local pool's `isSupportedChain(remoteSelector)` and that each declared
  rate-limit and policy value matches the live local pool. It does not read which remote pool address the
  local pool has registered for that lane.

So a pool can be doctor 0-FAIL for a lane, with `isSupportedChain(remote)` true and every rate limit
matching, while the remote pool it has registered points at a decommissioned pool. A transfer over that
lane then reverts `InvalidSourcePoolAddress` on release, because the destination pool validates the
message's `sourcePoolAddress` against its registered remote pools and the wired-in pool is not in the set.
See [Remove a remote pool](../operations/lanes-and-remotes.md#remove-a-remote-pool) for the same check at
release time.

After the doctor passes, cross-check each directed lane A to B: A's registered remote pool for B must be
B's currently wired pool. Read B's wired pool from its `TokenAdminRegistry`, then read A's registered
remote pools for the lane to B:

```bash
# B's currently wired pool (the TokenAdminRegistry entry on B)
forge script script/setup/GetTokenConfig.s.sol --rpc-url $B_RPC_URL
#   -> Token Config: tokenPool: 0x<B-wired-pool>

# A's registered remote pools for the lane to B
DEST_CHAIN=<B-name> \
  forge script script/configure/remote-pools/GetRemotePools.s.sol --rpc-url $A_RPC_URL
#   -> Remote Pools: [0] 0x<addr>   this list must contain 0x<B-wired-pool>
```

`0x<B-wired-pool>` must appear in A's `Remote Pools` list. Run it for both directions of every lane
(`2N` checks for a one-chain addition). This is still a read-only loop over the existing scripts, no new
primitive: [`GetTokenConfig`](../primitives/token-admin-registry/GetTokenConfig.md) reads the wired pool
and [`GetRemotePools`](../primitives/remote-pools/GetRemotePools.md) reads the registered set. Doctor
clean plus this cross-check green each way is what proves the mesh, the same way a static check plus a
real round-trip proves a single lane in the [health check](health-check.md).
