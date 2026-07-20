---
type: guide
---

# Production checklist

The ordered list to walk before a mainnet launch. Each item names the primitive or make target that
proves it. Do not skip the read-backs: a setting you did not read back is a setting you did not make.

## 0. Funding and access

- [ ] Native gas confirmed on the deployer AND on the Safe, on every chain you deploy or govern
      (`cast balance <account> --rpc-url ...`). A Safe that cannot pay gas cannot execute the emergency
      throttle in section 4.
- [ ] The sending wallet holds the fee token (LINK or native) for the smoke send and for real traffic.
- [ ] Safe signers and threshold are reachable (you can actually collect the required signatures).

## 1. Pin and build

- [ ] GA contracts pinned (`@chainlink/contracts-ccip` at the intended version) and `forge build --deny
      warnings` is clean.
- [ ] Every documented command has been run at least once against the final code.

## 2. Deploy and register

- [ ] Token and pool deployed, source-verified on the explorer (`make deploy-token` / `make deploy-pool`
      with `VERIFY=1`, or `make verify`), and recorded in the project store.
- [ ] Token admin registered and accepted, and the pool set (`make doctor` confirms on-chain code at the
      recorded token and pool addresses).

## 3. Roles handed off

- [ ] Privileged roles moved to the intended holder (Safe) with the EOA-to-Safe ceremony, and
      `make roles-check CHAIN=<name>` reports clean (exit 0). See [roles](roles.md).
- [ ] The two governance axes are both correct: pool ownership AND the TokenAdminRegistry administrator.
      A timelock owning the pool does not delay-gate a set-pool cutover unless the registry administrator
      moves under it too.

## 4. Rate limits set and read back

- [ ] Inbound and outbound rate limits set on both sides of every lane and read back
      (`make`-wrapped `UpdateRateLimiters` then `GetCurrentRateLimits`). Values are in the token's
      smallest unit; recompute per token and lane.
- [ ] The `rateLimitAdmin` is on the fast-response holder (Safe) for emergency throttles.
- [ ] You know the pause pattern for your pool version (an enabled limiter throttled to near zero;
      `capacity=1, rate=1` reverts on v1.5.x, valid on v1.6+/v2.0). See [pool versions](pool-versions.md).

## 5. Lanes confirmed in all directions

- [ ] Every lane confirmed in both directions (`make doctor` on each chain; remote pools present, no
      chain supported with zero pools).
- [ ] A smoke transfer sent and tracked in each direction, and its status confirmed `SUCCESS`.
- [ ] **LockRelease only:** the destination lockbox (v2) or pool (v1) is funded with release liquidity,
      and the balance is read back at or above your expected first-day release volume. An empty lockbox
      passes doctor, roles, and rate limits and even the outbound smoke send's source leg, then every
      inbound transfer sticks. See [liquidity](operations/liquidity.md).

## 6. Migration and rollback plan

- [ ] A migration and rollback plan is referenced and understood (pool v1-to-v2 coexistence is not
      reachable through the deploy scripts; the migration guide points at the proven fixture).
- [ ] You have verified the transfer preflight for your first real send (dest liquidity, finality)
      so a stuck message is caught before it happens.

## 7. Monitoring and incident readiness

- [ ] A watch is running on each lane before launch: CCIP Explorer or `GET /v2/messages` polling for
      stuck or failed transfers.
- [ ] Alerts on rate-limiter capacity and on pool or lockbox balance (so a draining lockbox is caught
      before it strands transfers).
- [ ] An incident runbook is written and the emergency throttle rehearsed: who throttles via the
      `rateLimitAdmin` Safe, and who runs a [manual execution](guides/send-track-diagnose.md) for a stuck
      recoverable message. The smoke send proves the lane once; monitoring proves it stays up.
