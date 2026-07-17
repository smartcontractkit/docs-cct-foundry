#!/usr/bin/env bash
# verify-contract.sh - source-verify one already-deployed contract on <chain>'s explorer backend
# (the standalone BACKFILL path; a fresh deploy verifies inline with `forge script ... --verify`).
#
# Usage: bash script/config/verify-contract.sh <selectorName> <address> <path:ContractName> [ctor-args]
#   ctor-args: ABI-encoded constructor arguments (`cast abi-encode "constructor(...)" ...`). Omit to
#   let forge extract them from the on-chain creation code (--guess-constructor-args, needs the RPC).
#
# The verifier backend comes from the chain's optional verifier{type,url} block via verify-args.sh
# (no verifier{} = Etherscan v2, resolved by forge from the chain id). "Contract not available on the
# explorer yet" is indexer lag, so every attempt runs --watch --retries 10 --delay 10; an
# already-verified contract is SUCCESS, not an error. Blockscout can report failure before its
# bytecode import finishes, so a failed attempt is retried up to 3 times before it counts.
set -uo pipefail
cd "$(dirname "$0")/../.."

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "[verify] usage: bash script/config/verify-contract.sh <selectorName> <address> <path:ContractName> [ctor-args]" >&2
    exit 1
fi
name="$1"
address="$2"
contract="$3"
ctor_args="${4:-}"

flags="$(bash script/config/verify-args.sh "$name")" || exit 1
file="config/chains/${name}.json"
chain_id="$(jq -r '.chainId' "$file")"
rpc_env="$(jq -r '.rpcEnv' "$file")"
rpc_url="${!rpc_env:-}"

# shellcheck disable=SC2086 # $flags is a composed flag list, word-splitting is the point
cmd=(forge verify-contract --chain "$chain_id" --watch --retries 10 --delay 10 $flags)
if [ -n "$ctor_args" ]; then
    cmd+=(--constructor-args "$ctor_args")
else
    if [ -z "$rpc_url" ]; then
        echo "[verify] no ctor-args given and ${rpc_env} is unset - --guess-constructor-args needs the RPC. Pass ctor-args or export ${rpc_env}" >&2
        exit 1
    fi
    cmd+=(--guess-constructor-args --rpc-url "$rpc_url")
fi
cmd+=("$address" "$contract")

for attempt in 1 2 3; do
    out="$("${cmd[@]}" 2>&1)"
    status=$?
    echo "$out"
    if [ $status -eq 0 ]; then
        echo "[verify] OK: ${contract} at ${address} on ${name}"
        exit 0
    fi
    if grep -qi "already verified" <<< "$out"; then
        echo "[verify] OK (already verified): ${contract} at ${address} on ${name}"
        exit 0
    fi
    if [ $attempt -lt 3 ]; then
        # VERIFY_RETRY_SLEEP shortens the wait in tests; the default outlasts a Blockscout import.
        echo "[verify] attempt ${attempt} failed (explorer indexer may still be importing) - retrying in ${VERIFY_RETRY_SLEEP:-15}s" >&2
        sleep "${VERIFY_RETRY_SLEEP:-15}"
    fi
done
echo "[verify] FAILED after 3 attempts: ${contract} at ${address} on ${name}" >&2
exit 1
