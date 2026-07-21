---
type: index
---

# Guides

Task-to-page map. Each outcome links the page with the exact commands: an operations reference page, a
concept page, or a dedicated guide. Grouping is for navigation only.

## Onboarding and tokens

- [Onboard a chain from the CCIP API](../operations/chains.md) (`make discover` / `add-chain` / `doctor`).
- [Launch a BurnMint token and pool](../operations/tokens.md), then its [pool](../operations/pools.md).
- [Launch a LockRelease token and pool](../operations/pools.md), and choose a [liquidity model](../operations/liquidity.md).
- [Bring your own existing token (adoption)](../enabling-existing-token.md).
- [Manage multiple tokens with token groups](../concepts/store-model.md).
- [Configure a lane (remote pool plus rate limits)](../operations/lanes-and-remotes.md).

## Configure v2 pool features

- [Required verifiers (CCV) per lane](../operations/ccv.md).
- [Advanced Pool Hooks and the additional-CCV threshold](../operations/hooks-allowlist.md).
- [Per-lane token-transfer fees](../operations/fees.md).
- [Fast finality and fast-finality rate limits](../operations/finality.md).
- [Rate limits (set, pause, remove) and the version deltas](../operations/rate-limits.md).
- [LockRelease liquidity: rebalancer vs ERC20 LockBox](../operations/liquidity.md).
- [Allowlist, authorized callers, and dynamic config](../operations/hooks-allowlist.md).

## Govern

- [Operate under a Safe: modes and batching](../governance-modes.md), and the
  [EOA-to-Safe roles handoff ceremony](../roles.md#the-eoa--safe-handoff-ceremony).

## Operate and maintain

- [Expand the mesh: add or remove lanes both ways](../operations/lanes-and-remotes.md), then `make doctor`.
- [Verify deployed contracts on the explorer](../operations/verification.md).
- [Health-check a deployment before mainnet](health-check.md).
- [Preflight a transfer before sending](preflight-a-transfer.md).
- [Migrate a pool from v1 to v2](migrate-pool-v1-to-v2.md).
- [Send, track, manually execute, and diagnose a transfer](send-track-diagnose.md).
