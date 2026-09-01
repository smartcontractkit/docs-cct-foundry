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
    echo "                     WALLET=<ccip-cli --wallet spec, e.g. foundry:<account>>" >&2
    exit 2
}

[ -n "$SOURCE_CHAIN" ] && [ -n "$DEST_CHAIN" ] && [ -n "$AMOUNT_WEI" ] && [ -n "$RECEIVER" ] || usage

for c in "$SOURCE_CHAIN" "$DEST_CHAIN"; do
    [ -f "$CONFIG_DIR/$c.json" ] || {
        echo "unknown chain '$c' - no $CONFIG_DIR/$c.json" >&2
        exit 2
    }
done

for _bin in ccip-cli jq; do
    command -v "$_bin" > /dev/null 2>&1 || {
        echo "$_bin not found" >&2
        if [ "$_bin" = "ccip-cli" ]; then
            echo "       install it: npm i -g @chainlink/ccip-cli" >&2
        fi
        exit 2
    }
done

router="$(jq -r '.ccip.router // empty' "$CONFIG_DIR/$SOURCE_CHAIN.json")"
[ -n "$router" ] || {
    echo "no .ccip.router in $CONFIG_DIR/$SOURCE_CHAIN.json - run: make sync CHAIN=$SOURCE_CHAIN" >&2
    exit 2
}

# Both RPCs: the source leg and the dest leg are simulated on their own chains.
rpcs=()
for c in "$SOURCE_CHAIN" "$DEST_CHAIN"; do
    env_name="$(jq -r '.rpcEnv // empty' "$CONFIG_DIR/$c.json")"
    url="$(bash script/config/dotenv-get.sh "$env_name")"
    [ -n "$url" ] || {
        echo "RPC not set for $c - set $env_name in ./.env, or export it" >&2
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

# The estimate is a DESTINATION-side simulation, so the sender is what the destination sees (a
# receiver that gates on it, and the dest pool's releaseOrMint) - not the source pool's allowlist,
# which nothing on this path evaluates. ccip-cli resolves it in one order (providers/index.ts):
# --wallet, else PRIVATE_KEY/USER_KEY/OWNER_KEY from the environment, else those same names read out
# of ./.env. With none of them the estimate simply is not sender-scoped.
[ -z "${ORIGINAL_SENDER:-}" ] || {
    echo "ORIGINAL_SENDER is not supported: ccip-cli's --wallet takes a wallet spec, not an address," >&2
    echo "       so it cannot scope the estimate to an address you do not hold a key for. Passing one" >&2
    echo "       is also worse than passing nothing - it occupies --wallet and suppresses the" >&2
    echo "       PRIVATE_KEY resolution that would otherwise have produced a sender." >&2
    echo "       Use WALLET=foundry:<keystore account>, or leave both unset." >&2
    exit 2
}

sender_args=()
if [ -n "${WALLET:-}" ]; then
    sender_args=(--wallet "$WALLET")
    case "$WALLET" in
        foundry:*)
            # Checked here because ccip-cli does not fail on either of these: --no-interactive turns a
            # missing password into an error it CATCHES ("pass undefined sender as default"), so a
            # keystore it cannot open silently becomes an unscoped estimate that arrives here as a GO.
            ks_name="${WALLET#foundry:}"
            ks_path="${FOUNDRY_DIR:-$HOME/.foundry}/keystores/$ks_name"
            [ -f "$ks_path" ] || {
                echo "no Foundry keystore '$ks_name' at $ks_path - list them: cast wallet list" >&2
                exit 2
            }
            ks_pw="$(bash script/config/dotenv-get.sh FOUNDRY_KEYSTORE_PASSWORD)"
            [ -n "$ks_pw" ] || ks_pw="$(bash script/config/dotenv-get.sh USER_KEY_PASSWORD)"
            [ -n "$ks_pw" ] || {
                echo "keystore '$ks_name' needs its password to scope the estimate - set" >&2
                echo "       FOUNDRY_KEYSTORE_PASSWORD (or USER_KEY_PASSWORD) in ./.env, or export it." >&2
                echo "       Without WALLET the estimate still runs, just not scoped to a sender." >&2
                exit 2
            }
            # ccip-cli reads this from the environment only, so it has to be exported, not just set.
            export FOUNDRY_KEYSTORE_PASSWORD="$ks_pw"
            ;;
    esac
else
    # Say so rather than let a GO imply a sender-scoped answer it did not give.
    for _k in PRIVATE_KEY USER_KEY OWNER_KEY; do
        [ -n "$(bash script/config/dotenv-get.sh "$_k")" ] && sender_known=1 && break
    done
    [ -n "${sender_known:-}" ] || echo "note: no wallet and no PRIVATE_KEY/USER_KEY/OWNER_KEY," \
        "so this estimate is not scoped to a sender (set WALLET=foundry:<account> to scope it)."
fi

echo "preflight: $SOURCE_CHAIN -> $DEST_CHAIN, $amount_human of $token to $RECEIVER (nothing is sent)"

# `--json` (the CLI's alias for --format=json) so the answer is parsed, not read off a pretty table
# whose wording is free to change. It splits the streams too: stdout carries only the estimate object,
# while logs and errors go to stderr, so the two are captured apart rather than through 2>&1.
# Captured, not piped: a pipeline reports the LAST command's status, which would mask a NO-GO.
_err="$(mktemp)"
out="$(ccip-cli send \
    --source "$SOURCE_CHAIN" --dest "$DEST_CHAIN" \
    --router "$router" --receiver "$RECEIVER" \
    --transfer-tokens "$token=$amount_human" \
    --rpcs "${rpcs[@]}" \
    --only-estimate --estimate-gas-limit 0 --no-interactive --json \
    "${sender_args[@]}" 2> "$_err")"
rc=$?
err="$(cat "$_err")"
rm -f "$_err"
[ -n "$err" ] && printf '%s\n' "$err" >&2

# A GO has to be positively evidenced: exit 0 AND a parseable estimate on stdout. Exit 0 with nothing
# to parse means the run produced no answer, which is not the same as producing a favourable one.
if [ $rc -eq 0 ]; then
    if printf '%s' "$out" | jq -e . > /dev/null 2>&1; then
        echo "GO: no blocking verdict (estimated destination gas:" \
            "$(printf '%s' "$out" | jq -r '.estimated // "n/a"')). Not checked here: your token" \
            "balance, the Router allowance, and the source pool's allowlist and rate limits."
        exit 0
    fi
    echo "UNRESOLVED: ccip-cli exited 0 without a parseable estimate, so it reached no verdict." >&2
    exit 2
fi

# A nonzero exit is not automatically a verdict. `--only-estimate` rethrows every error the estimate
# raises (ccip-cli send.ts: "if (argv.estimateGasLimit != null || argv.onlyEstimate) throw err"),
# including the one its own source calls "inconclusive, not a verdict" - so an unreachable dest RPC,
# a bad flag, or an unknown chain all arrive here looking exactly like "your transfer would fail".
# Reporting those as NO-GO tells a user their healthy lane is broken. Only a verdict the CLI actually
# reached gets exit 1; everything structurally identifiable as a tooling failure gets exit 2.
#
# `.env('CCIP')` + `.strict()` in the CLI means every CCIP_* var in the environment becomes an
# option, so a stray one (CCIP_API_BASE ships commented-out in .env.example) is a usage error here.
case "$err" in
    *"error[DEST_SIMULATION_UNAVAILABLE]"* | *"error[RPC_NOT_FOUND]"* | *"error[HTTP_ERROR]"* | \
        *"error[CHAIN_NOT_FOUND]"* | *"error[LANE_NOT_FOUND]"* | *"error[INTERACTIVE_REQUIRED]"* | \
        *"error[ARGUMENT_INVALID]"* | *"Unknown argument"* | *"Missing dependent arguments"* | \
        *"Missing required argument"* | *"Not enough non-option arguments"*)
        echo "UNRESOLVED: ccip-cli could not reach a verdict (exit $rc) - this is a tooling or" \
            "configuration failure, not evidence about the transfer." >&2
        exit 2
        ;;
esac
echo "NO-GO: the transfer would not complete as asked (see the verdict above)." >&2
exit 1
