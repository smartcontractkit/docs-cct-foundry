#!/usr/bin/env bash
# verify-execution.sh <messageId> <destChain>: READ-ONLY destination-execution check, wrapping
# `ccip-cli show`.
#
# Answers one question: did this CCIP message execute on the destination? The CCIP index is the
# authority here, not the destination OffRamp: `ccip-cli` is version-agnostic (the on-chain
# `getExecutionState` getter takes a sequence number on `EVM2EVMOffRamp 1.5.0` and two arguments on
# later versions, so a direct call must resolve `typeAndVersion` first) and it returns the revert
# decoded rather than as a bare integer.
#
# <destChain> is a `config/chains/` file name (e.g. ethereum-testnet-sepolia). It does two things:
# it cross-checks that the message really is destined for that chain, so a typo cannot return a
# confident green, and it supplies that chain's `rpcEnv` RPC to `ccip-cli` when one is exported.
# The RPC is OPTIONAL: the index answers on its own, and the RPC only adds on-chain corroboration.
#
# Exit-code contract (owned by THIS script; callers and CI rely on it):
#   0  EXECUTED       the message executed successfully on the destination (state 2)
#   1  FAILED         the message executed and reverted (state 3); the decoded reason is printed
#   2  PENDING        no destination execution receipt yet; the message is still in flight
#   3  UNRESOLVED     the message is unknown, destined elsewhere, the CLI could not be queried, or the
#                     args were bad (a tooling/caller problem, never evidence about the message)
#
# Call THIS SCRIPT directly for those codes. `make verify-execution` is pass/fail only, because GNU
# make remaps any failing recipe to its own exit 2, collapsing FAILED, PENDING and UNRESOLVED into
# one value (same reason `make sync-check` and `make roles-check` are pass/fail only).
#
# A message that FAILED and was later recovered reports only the final SUCCESS here, because the index
# keeps the last state. To see an earlier failed attempt, enumerate every `ExecutionStateChanged` for
# the messageId on the destination OffRamp; that history is on-chain only.
set -uo pipefail

cd "$(dirname "$0")/../.."

MESSAGE_ID="${1:-}"
DEST_CHAIN="${2:-}"

if [ -z "$MESSAGE_ID" ] || [ -z "$DEST_CHAIN" ]; then
    echo "usage: verify-execution.sh <messageId> <destChain>" >&2
    echo "       destChain is a config/chains/ file name, e.g. ethereum-testnet-sepolia" >&2
    exit 3
fi

for _bin in ccip-cli jq; do
    if ! command -v "$_bin" > /dev/null 2>&1; then
        echo "verify-execution: $_bin is required but not installed" >&2
        if [ "$_bin" = "ccip-cli" ]; then
            echo "       install it: npm i -g @chainlink/ccip-cli (>= 1.10)" >&2
        fi
        exit 3
    fi
done

CHAIN_FILE="config/chains/${DEST_CHAIN}.json"
if [ ! -f "$CHAIN_FILE" ]; then
    echo "verify-execution: unknown destChain '$DEST_CHAIN' (no $CHAIN_FILE)" >&2
    exit 3
fi
EXPECTED_SELECTOR="$(jq -r '.chainSelector // empty' "$CHAIN_FILE")"

# A value in .env maps to a non-existent CLI option and crashes ccip-cli's strict parser.
unset CCIP_API_URL

# The destination RPC is optional corroboration, not a requirement: the CCIP index answers without it.
# Read it from the environment if the chain's rpcEnv var is exported (export it, or source .env, to add
# the on-chain read); the safety property, the selector cross-check below, needs only the index.
_rpc=""
_rpc_env="$(jq -r '.rpcEnv // empty' "$CHAIN_FILE")"
[ -n "$_rpc_env" ] && _rpc="$(printenv "$_rpc_env" || true)"

_err="$(mktemp)"
trap 'rm -f "$_err"' EXIT
if [ -n "$_rpc" ]; then
    _out="$(ccip-cli show "$MESSAGE_ID" --rpcs "$_rpc" --no-interactive -f json 2> "$_err")"
else
    _out="$(ccip-cli show "$MESSAGE_ID" --no-interactive -f json 2> "$_err")"
fi
_cli_status=$?

# A nonzero CLI exit is a tooling problem, never evidence about the message. Swallowing it would let a
# lookup failure surface as PENDING, i.e. "wait longer", on a check that authorises a destructive
# cleanup. Print only the head of the CLI's stderr: it emits a full Node stack trace.
if [ $_cli_status -ne 0 ] || [ -z "$_out" ] || ! printf '%s' "$_out" | jq -e . > /dev/null 2>&1; then
    echo "UNRESOLVED  $MESSAGE_ID (ccip-cli exit $_cli_status)"
    head -3 "$_err" | sed 's/^/            /' >&2
    echo "            the message may still be propagating, or the id is wrong" >&2
    exit 3
fi

# A typo'd destChain must not return a confident green, so require the message to agree.
_actual_selector="$(printf '%s' "$_out" | jq -r '
    [.. | objects | .destChainSelector? // empty] | map(tostring) | first // empty')"
if [ -n "$_actual_selector" ] && [ -n "$EXPECTED_SELECTOR" ] && [ "$_actual_selector" != "$EXPECTED_SELECTOR" ]; then
    echo "UNRESOLVED  $MESSAGE_ID (destined for selector $_actual_selector, not $DEST_CHAIN/$EXPECTED_SELECTOR)"
    exit 3
fi

# Read the state as an integer: the API renders it as a JSON number, so jq can print it as `2.0`.
_state="$(printf '%s' "$_out" | jq -r '
    .receipts[-1].receipt.state | if . == null then empty else (floor | tostring) end')"

if [ -z "$_state" ]; then
    echo "PENDING     $MESSAGE_ID (no destination execution receipt yet)"
    exit 2
fi

case "$_state" in
    2)
        echo "EXECUTED    $MESSAGE_ID (state 2)"
        exit 0
        ;;
    3)
        echo "FAILED      $MESSAGE_ID (state 3)"
        printf '%s' "$_out" | jq -r '
            .receipts[-1].error
            | if . == null then "  (no decoded reason; see receipts[-1].receipt.returnData)"
              else to_entries | map("  \(.key): \(.value)") | join("\n") end'
        exit 1
        ;;
    *)
        echo "PENDING     $MESSAGE_ID (state $_state, not yet terminal)"
        exit 2
        ;;
esac
