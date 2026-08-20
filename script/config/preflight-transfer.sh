#!/usr/bin/env bash
# preflight-transfer.sh <sourceChain> <destChain> <amountWei> <receiver>: READ-ONLY GO/NO-GO for a
# token transfer, wrapping `ccip-cli send --only-estimate`.
#
# Nothing is sent. `--only-estimate` runs the CLI's pre-send checks and exits: both pool legs are
# simulated (source `lockOrBurn`, then dest `releaseOrMint` fed the `destPoolData` the source leg
# produced), plus the OffRamp lane gates and the v2 CCV/finality resolve. The pool legs are reachable
# because they gate only on `msg.sender` being a registered ramp, which an `eth_call` satisfies with a
# spoofed `from`; the full `ccipSend`/`execute()` cannot be simulated pre-send (proof-gated).
#
# This replaced a Foundry script that simulated the same two legs. The CLI does strictly more - lane
# gates the pool-direct simulation structurally bypasses, post-fee amounts for v2 bps-charging pools,
# a transient-vs-permanent revert taxonomy, and non-EVM destinations Foundry cannot reach at all.
#
# AMOUNT IS IN WEI, matching every other target here. `ccip-cli -t token=amount` takes HUMAN units
# (`parseUnits(amount, decimals)`), so this converts. Passing wei straight through would overstate the
# transfer by 10^decimals and turn a NO-GO into a rate-limit error about an amount nobody asked for.
#
# Exit-code contract (owned by THIS script):
#   0  GO          the CLI completed its checks without a blocking verdict
#   1  NO-GO       a definitive verdict (source or dest pool would revert, rate limit, lane closed)
#   2  UNRESOLVED  bad arguments, missing config, no RPC, or ccip-cli absent - never a verdict
#
# Two checks the CLI deliberately does NOT make, because its `eth_call` state override masks them:
# the sender's own token balance and Router allowance. Verify those separately before sending.
#
# One known gap on the SOURCE leg: `Error(string)` and `Panic(uint256)` reverts are treated as
# artifacts of that balance override and do not block. A pool using string-revert access control for
# burn authority (legacy OpenZeppelin) is therefore not covered; modern chainlink-ccip pools use
# custom errors and are.
set -uo pipefail

cd "$(dirname "$0")/../.."

SOURCE_CHAIN="${1:-}"
DEST_CHAIN="${2:-}"
AMOUNT_WEI="${3:-}"
RECEIVER="${4:-}"
CONFIG_DIR="config/chains"

usage() {
    echo "usage: preflight-transfer.sh <sourceChain> <destChain> <amountWei> <receiver>" >&2
    echo "       chains are $CONFIG_DIR file names, e.g. ethereum-testnet-sepolia" >&2
    echo "       optional env: TOKEN=<addr> (else resolved from the project store)," >&2
    echo "                     ORIGINAL_SENDER=<addr> or WALLET=<ccip-cli --wallet spec>" >&2
    exit 2
}

[ -n "$SOURCE_CHAIN" ] && [ -n "$DEST_CHAIN" ] && [ -n "$AMOUNT_WEI" ] && [ -n "$RECEIVER" ] || usage

for c in "$SOURCE_CHAIN" "$DEST_CHAIN"; do
    [ -f "$CONFIG_DIR/$c.json" ] || {
        echo "unknown chain '$c' - no $CONFIG_DIR/$c.json" >&2
        exit 2
    }
done

command -v ccip-cli > /dev/null 2>&1 || {
    echo "ccip-cli not found - install it: npm i -g @chainlink/ccip-cli" >&2
    exit 2
}

router="$(jq -r '.ccip.router // empty' "$CONFIG_DIR/$SOURCE_CHAIN.json")"
[ -n "$router" ] || {
    echo "no .ccip.router in $CONFIG_DIR/$SOURCE_CHAIN.json - run: make sync CHAIN=$SOURCE_CHAIN" >&2
    exit 2
}

# Both RPCs: the source leg and the dest leg are simulated on their own chains.
rpcs=()
for c in "$SOURCE_CHAIN" "$DEST_CHAIN"; do
    env_name="$(jq -r '.rpcEnv // empty' "$CONFIG_DIR/$c.json")"
    url="$(printenv "$env_name" || true)"
    [ -n "$url" ] || {
        echo "RPC not set for $c - export $env_name=<url>" >&2
        exit 2
    }
    rpcs+=("$url")
done

# The token: explicit, else the source chain's active token from the project store.
token="${TOKEN:-}"
if [ -z "$token" ]; then
    store="project/${PROJECT_GROUP:+$PROJECT_GROUP/}$SOURCE_CHAIN.json"
    token="$(jq -r '.addresses.active.token // empty' "$store" 2> /dev/null || true)"
fi
[ -n "$token" ] || {
    echo "no token - pass TOKEN=<addr>, or deploy one so the project store records it" >&2
    exit 2
}

# wei -> human units, because `-t` parses with the token's decimals.
decimals="$(cast call "$token" 'decimals()(uint8)' --rpc-url "${rpcs[0]}" 2> /dev/null || true)"
[ -n "$decimals" ] || {
    echo "could not read decimals() on $token - is it the token address?" >&2
    exit 2
}
amount_human="$(cast to-unit "$AMOUNT_WEI" "$decimals" 2> /dev/null || true)"
[ -n "$amount_human" ] || {
    echo "could not convert AMOUNT=$AMOUNT_WEI to $decimals-decimal units" >&2
    exit 2
}

# The source pool gates its allowlist on the SENDER, so who asks changes the answer. Unset, ccip-cli
# resolves its own default; ORIGINAL_SENDER/WALLET make it explicit.
sender_args=()
if [ -n "${WALLET:-}" ]; then
    sender_args=(--wallet "$WALLET")
elif [ -n "${ORIGINAL_SENDER:-}" ]; then
    sender_args=(--wallet "$ORIGINAL_SENDER")
fi

echo "preflight: $SOURCE_CHAIN -> $DEST_CHAIN, $amount_human of $token to $RECEIVER (nothing is sent)"

# Captured, not piped: a pipeline reports the LAST command's status, which would mask a NO-GO.
out="$(ccip-cli send \
    --source "$SOURCE_CHAIN" --dest "$DEST_CHAIN" \
    --router "$router" --receiver "$RECEIVER" \
    --transfer-tokens "$token=$amount_human" \
    --rpcs "${rpcs[@]}" \
    --only-estimate --estimate-gas-limit 0 --no-interactive \
    "${sender_args[@]}" 2>&1)"
rc=$?
echo "$out"

if [ $rc -eq 0 ]; then
    echo "GO: no blocking verdict. Not checked here: your token balance and Router allowance."
    exit 0
fi
echo "NO-GO: the transfer would not complete as asked (see the verdict above)." >&2
exit 1
