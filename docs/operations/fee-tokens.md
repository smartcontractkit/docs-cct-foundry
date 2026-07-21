---
type: reference
---

# Fee token balances

Inspect and withdraw the fee token balances a token pool has accrued. Pool-level fee accrual and
withdrawal are introduced in TokenPool v2.0; against a v1 pool these scripts exit with an informative
message and suggest using FeeQuoter instead. Scripts under `script/operations/`. Primitive pages:
[`GetFeeTokenBalances`](../primitives/operations/GetFeeTokenBalances.md),
[`WithdrawFeeTokens`](../primitives/operations/WithdrawFeeTokens.md).

## Get fee token balances

Run this before `WithdrawFeeTokens`. It prints each token's balance and a pre-filled withdrawal command
for any non-zero tokens.

```bash
FEE_TOKENS="0xTokenA,0xTokenB" \
  forge script \
  script/operations/GetFeeTokenBalances.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL
```

## Withdraw fee tokens

Withdraws accrued fee token balances from a token pool to a specified recipient. Only callable by the
pool owner or the designated fee admin. The script makes no assumptions about which token(s) accumulated
as fees; you must specify them via `FEE_TOKENS` (a comma-separated list or JSON array). The pool token
address is printed at runtime so you can identify whether to include it.

```bash
# Single fee token
RECIPIENT=0xYourAddress \
  FEE_TOKENS="0xTokenThatAccruedFees" \
  forge script \
  script/operations/WithdrawFeeTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast

# Multiple fee tokens
RECIPIENT=0xYourAddress \
  FEE_TOKENS="0xFirstFeeToken,0xSecondFeeToken" \
  forge script \
  script/operations/WithdrawFeeTokens.s.sol \
  --rpc-url \
  $ETHEREUM_SEPOLIA_RPC_URL \
  --account \
  $KEYSTORE_NAME \
  --broadcast
```

| Env var      | Required | Description                                                               |
| ------------ | -------- | ------------------------------------------------------------------------- |
| `FEE_TOKENS` | Yes      | CSV or JSON array of ERC20 token addresses to withdraw                    |
| `RECIPIENT`  | No       | Address to receive the withdrawn fee tokens (defaults to the broadcaster) |
