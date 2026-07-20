---
type: reference
---

# CCV config

Token pools v2.0 and later verify cross-chain messages through CCVs (Cross-Chain Verifiers), configured
per lane on the pool's `AdvancedPoolHooks` contract: a required set of verifiers for each direction
(`outboundCCVs` / `inboundCCVs`) plus an optional additional set that applies once a transfer reaches (is
at or above) the threshold amount (`thresholdOutboundCCVs` / `thresholdInboundCCVs`). Because the config
lives on the hooks contract, these scripts resolve it via `pool.getAdvancedPoolHooks()`.

Scripts under `script/configure/ccv/`. Primitive pages:
[`GetCCVConfig`](../primitives/ccv/GetCCVConfig.md), [`UpdateCCVConfig`](../primitives/ccv/UpdateCCVConfig.md).
Concept background: [Verifiers (CCVs)](../concepts/verifiers-ccv.md).

The setter refuses by name on a pre-2.0.0 pool (the CCV surface is 2.0.0-only) or when no hooks contract
is wired; the getter degrades gracefully, printing an informative message instead of reverting.

## View CCV config

Reads the per-lane verifier arrays and the pool-global threshold.

```bash
forge script \
  script/configure/ccv/GetCCVConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

## Set or update CCV config

Each verifier array and the threshold resolve independently through the same ladder as the fee and
rate-limit scripts: an env var (a comma-separated address list) wins when set; an unset array takes the
declared `lanes.<remote>.v2.ccv.<field>` from `project/<local>.json` when the block declares it;
otherwise it keeps the current on-chain value. The golden path for v2 lanes is to declare the CCV set in
`v2.ccv` (and the threshold in the pool-scoped `poolPolicy.ccvThreshold`) and run the script with no CCV
env vars.

The read-modify-write is important: `applyCCVConfigUpdates` replaces a lane's whole entry, so the script
reads the current on-chain arrays first and overwrites only the arrays you declare. Changing
`OUTBOUND_CCVS` never wipes your inbound verifiers.

Env vars remain the explicit override for incident response: a value that disagrees with the declaration
(compared as a set, order-insensitive) is applied as-is with a divergence notice plus a hand-edit hint
(the `v2.ccv` block has no `make add-lane` flag; reconcile it with a reviewed hand edit), and `make
doctor` FAILs until reconciled. Applies never write `lanes{}` back.

```bash
DEST_CHAIN=MANTLE_SEPOLIA \
  OUTBOUND_CCVS=0xVerifierA,0xVerifierB \
  INBOUND_CCVS=0xVerifierC \
  forge script \
  script/configure/ccv/UpdateCCVConfig.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var                   | Required        | Description                                                                                                                                                                              |
| ------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEST_CHAIN`              | For lane arrays | Remote chain whose CCV set is being configured (omit to set only the pool-global threshold)                                                                                             |
| `OUTBOUND_CCVS`           | No              | Comma-separated required verifier addresses for outgoing messages (defaults to the declared `v2.ccv.outboundCCVs`, then the current on-chain value)                                     |
| `INBOUND_CCVS`            | No              | Comma-separated required verifier addresses for incoming messages (defaults to the declared value, then on-chain)                                                                       |
| `THRESHOLD_OUTBOUND_CCVS` | No              | Additional outbound verifiers required at or above the threshold amount; requires a non-empty outbound base set                                                                         |
| `THRESHOLD_INBOUND_CCVS`  | No              | Additional inbound verifiers required at or above the threshold amount; requires a non-empty inbound base set                                                                           |
| `CCV_THRESHOLD_AMOUNT`    | No              | Pool-global transfer amount at or above which the threshold verifier sets apply (defaults to the declared `poolPolicy.ccvThreshold`, then on-chain; `0` = no threshold)                 |
