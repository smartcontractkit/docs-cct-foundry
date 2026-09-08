#!/usr/bin/env bash
# sync-discover.sh — step 1 of onboarding a chain: list the CCIP REST API v2 chain catalog with
# local state awareness.
#
# Columns: DISPLAY NAME | API NAME | FAMILY | SELECTOR | CHAIN ID | STATUS. STATUS joins the local
# config/chains/*.json files **BY SELECTOR** (the numeric identity key). The config `name` now
# matches the API selectorName one-to-one (e.g. "ethereum-testnet-sepolia-mantle-1"), but the join
# stays on the selector. Shows `configured(<selectorName>)` vs `available`.
# FILTER=<term> filters case-insensitively across all columns.
#
# ENVIRONMENT=<testnet|mainnet> narrows to one plane; unset lists BOTH. This listed only testnet
# until a mainnet token could not be found through it - `make add-chain` was never restricted (it
# fetches /chains/<selector> directly), so the chain was addable all along, just invisible here.
#
# Exit codes: 0 OK | 2 MISSING_TOOL | 3 BAD_ARG | 5 API_UNREACHABLE
set -euo pipefail

err() { echo "[sync-discover] $*" >&2; }

for tool in curl jq; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH - install it (e.g. brew install $tool)"
        exit 2
    }
done

cd "$(dirname "$0")/../.."

BASE_URL="${CCIP_API_BASE:-https://api.ccip.chain.link/v2}"
FILTER="${FILTER:-}"

# Only the two values the API actually honours. It answers `environment=all` with HTTP 200 and an
# EMPTY chain list, so passing an unrecognised value straight through would print a clean, confident
# "no chains" - refuse by name instead.
ENVIRONMENT="${ENVIRONMENT:-}"
query=""
case "$ENVIRONMENT" in
    "") ;;
    testnet | mainnet) query="?environment=$ENVIRONMENT" ;;
    *)
        err "BAD_ARG: ENVIRONMENT='$ENVIRONMENT' - use testnet or mainnet, or leave it unset for both"
        exit 3
        ;;
esac

body_file="$(mktemp)"
map_file="$(mktemp)"
trap 'rm -f "$body_file" "$map_file"' EXIT

http_code="$(curl -sS --retry 3 --max-time 30 -o "$body_file" -w '%{http_code}' \
    "${BASE_URL}/chains${query}" 2> /dev/null)" || {
    err "API_UNREACHABLE: could not reach ${BASE_URL}/chains (network error/timeout) - retry later"
    exit 5
}
if [ "$http_code" != "200" ]; then
    err "API_UNREACHABLE: HTTP ${http_code} from ${BASE_URL}/chains${query} - retry later"
    exit 5
fi

# selector -> comma-joined local config names (skip the gitignored zz-scratch-* test files)
for f in config/chains/*.json; do
    case "$(basename "$f")" in zz-scratch-*) continue ;; esac
    jq -r '[(.chainSelector | tostring), .name] | @tsv' "$f"
done | awk -F'\t' '{ a[$1] = (a[$1] == "" ? $2 : a[$1] "," $2) } END { for (s in a) print s "\t" a[s] }' \
    > "$map_file"

{
    printf 'DISPLAY NAME\tAPI NAME\tFAMILY\tENV\tSELECTOR\tCHAIN ID\tSTATUS\n'
    jq -r '(if type == "array" then . else .chains end)[]
        | [(.displayName // .name), .name, (.chainFamily // "?"), (.environment // "?"),
           (.chainSelector | tostring), (.chainId | tostring)] | @tsv' "$body_file" |
        awk -F'\t' -v OFS='\t' '
            NR == FNR { cfg[$1] = $2; next }
            { status = ($5 in cfg) ? "configured(" cfg[$5] ")" : "available"; print $1, $2, $3, $4, $5, $6, status }
        ' "$map_file" - |
        { if [ -n "$FILTER" ]; then grep -i -- "$FILTER" || true; else cat; fi } |
        sort
} | column -t -s "$(printf '\t')"

echo ""
echo "onboard one: make add-chain CHAIN=<selectorName> SELECTOR=<selector>   (CHAIN = the API NAME column, verbatim;" \
    "FILTER=<term> narrows this list; ENVIRONMENT=<testnet|mainnet> narrows the plane, unset lists both)"
echo "        raw: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol" \
    "--sig \"init(string,uint256)\" <selectorName> <selector>"
