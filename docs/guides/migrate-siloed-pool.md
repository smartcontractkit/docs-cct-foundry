---
type: guide
---

# Migrate a Siloed LockRelease pool from 1.6 to 2.0

A 1.6.0 or 1.6.1 `SiloedLockReleaseTokenPool` holds its liquidity on the pool, one balance per siloed chain
plus a shared balance. A 2.0.0 pool holds none: each remote chain maps to an `ERC20LockBox`. Nothing can be
re-pointed, so the migration moves the tokens. The remote BurnMint pools follow
[migrate a pool from v1 to v2](migrate-pool-v1-to-v2.md).

## The workflow

1. **Deploy the 2.0 side.** `make deploy-siloed-pool`, one `make deploy-lockbox SILO=<label>` per silo and
   one for the shared chains, and the remote 2.0 pools with their mint and burn roles. Authorize the new
   pool, and the account that will move liquidity, on every box (`UpdateAuthorizedCallers`).
2. **Wire it.** `ConfigureLockBoxes` first, then `ApplyChainUpdates` for each lane of the new pools. Keep
   both generations reachable: `AddRemotePool` the old peer on every new pool and the new peer on every old
   pool, so a message committed against either side still releases.
3. **Move the liquidity**, as the pool owner and rebalancers:
   - Silo: `SetSiloRebalancer` (a mainnet silo may hold a placeholder rebalancer such as `0x…01`),
     `WithdrawSiloedLiquidity`, then `DepositToLockBox` into that silo's box.
   - Shared: `SetRebalancer`, `WithdrawLiquidity`, then `DepositToLockBox` into the shared box.
   - Leave a buffer on the old pool that covers inbound messages still in flight: they release from the old
     pool, and fail until refunded if it is empty.
4. **Cut over.** `SetPool` on every chain.
5. **Validate and sweep.** One transfer per directed lane on the new pools, then, after the drain window,
   move the old pool's buffer into the boxes.
6. **Retire the old generation.** `RemoveRemotePool` the old peer from every new pool, `RemoveChain` every
   lane of the old pools, and `RevokeTokenRole` the old burn-mint pools' minter and burner roles. Then
   `make forget-deployment NAME=<old pool key>` on each chain: doctor warns while two pools are recorded,
   and the command refuses a pool that is still registered, still has lanes, or is still `active`.

`GetSiloedPoolState` reads either generation's layout; run it before and after each step. Every write
above supports `MODE=safe`. A timelock-owned pool needs the same calls scheduled through its timelock.

## Checks that catch real mistakes

- Box balances per chain after step 3 equal the old per-chain balances minus the buffer.
- A 2.0 pool keeps its transfer fee on the pool; reconcile liquidity from the boxes only.
- The ccip-sdk reads a LockRelease destination's balance through `getLockBox()`, which a Siloed 2.0 pool
  does not have, so any balance figure it reports for one is not the box balance. With ccip-cli 1.13.0,
  sends and `make preflight` into a Siloed 2.0 pool still went through on the v2 staging plane; read the
  boxes with `GetSiloedPoolState` rather than trusting a reported balance.
