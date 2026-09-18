#!/usr/bin/env bash
# discover-tokens.sh - list the CCIP REST API v2 TOKEN catalog for an operator, with local state
# awareness. The `make discover` sibling: that one lists chains (`GET /chains`), this one lists
# tokens (`GET /tokens`).
#
# Columns: CHAIN SELECTOR | CHAIN | TOKEN | SYMBOL | GROUP | LANES | LOCAL CONFIG. LANES counts the
# remoteChains entries with status CONNECTED (the array also carries DISCONNECTED ones). LOCAL CONFIG
# joins config/chains/*.json **BY SELECTOR**, the numeric identity key, exactly as sync-discover.sh
# does.
#
# Filters, all optional and all env-driven: ADMIN (TokenAdminRegistry administrator), SYMBOL,
# CHAIN_SELECTOR (home chain), ENVIRONMENT (testnet|mainnet; unset lists both planes). There is no
# flag interface: the script takes no arguments at all.
#
# POOL=1 adds POOL, POOL TYPE and POOL VERSION from the per-token detail endpoint, one extra request per
# row, so narrow the listing first. These are the API's values: `type` is its enum (SILOED_LOCK_RELEASE),
# not the contract name, and `version` is null for a dev build. The exact typeAndVersion() is on-chain only.
# A detail request that fails shows `?` rather than aborting the listing.
#
# TWO PARAMETERS THIS SENDS EXPLICITLY, because their defaults are wrong for an operator:
#   reviewedOnly=false  - defaults to TRUE, i.e. only Chainlink-Labs-reviewed projects. Measured:
#                         ?environment=testnet returns 22 tokens, &reviewedOnly=false returns ~25,900,
#                         and with an admin= filter the default returns a confident totalCount 0 for
#                         an operator who has 169. HTTP 200, well-formed, no error - a silent wrong
#                         answer. See docs/reference/ccip-api.md.
#   expand=true         - defaults to FALSE, which strips `status` from every remoteChains entry, so
#                         the CONNECTED count cannot be computed at all.
#
# Paging is KEYSET, not offset (`page`/`offset` are rejected with a 400): follow pagination.cursor
# while pagination.hasNextPage. Stopping after page 1 silently truncates the operator's list.
#
# AN EMPTY RESULT IS A NORMAL ANSWER, NOT AN ERROR - exit 0. The API lists a token only once its mesh
# is fully configured, so a mesh still being wired is legitimately absent. It is never evidence that
# anything is wrong.
#
# Exit codes: 0 OK (including zero matches) | 2 MISSING_TOOL | 3 BAD_ARG | 5 API_UNREACHABLE |
#             6 BAD_BODY. Matches sync-discover.sh, its direct sibling, which in turn shares the
#             ccip-config-source.sh contract. 1 is deliberately unused: everywhere in this repo it
#             means a verdict against what the operator owns, and a read-only listing has no verdict
#             to issue - a transport or parse failure must never read as "you have no tokens".
#             `make discover-tokens` is pass/fail only, since GNU make remaps any failing recipe to
#             its own exit 2; call this script directly for the codes (same as probe-chain.sh).
set -euo pipefail

err() { echo "[discover-tokens] $*" >&2; }

# A flag-style `--admin 0x...` would otherwise be silently dropped and list the WHOLE catalog
# unfiltered - the same shape of confident wrong answer as the reviewedOnly default.
if [ "$#" -gt 0 ]; then
    err "BAD_ARG: unexpected argument '$1' - discover-tokens takes no arguments"
    err "         filters are environment variables: ADMIN= SYMBOL= CHAIN_SELECTOR= ENVIRONMENT= (make discover-tokens ADMIN=0x...)"
    exit 3
fi

for tool in curl jq; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH - install it (e.g. brew install $tool)"
        exit 2
    }
done

cd "$(dirname "$0")/../.."

BASE_URL="${CCIP_API_BASE:-https://api.ccip.chain.link/v2}"
ADMIN="${ADMIN:-}"
SYMBOL="${SYMBOL:-}"
CHAIN_SELECTOR="${CHAIN_SELECTOR:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
POOL="${POOL:-}"

uri() { jq -rn --arg v "$1" '$v | @uri'; }

# Only the two values the API honours; it answers an unrecognised one with 200 and an EMPTY list,
# which would print a confident "no tokens". Refuse by name before any request (same as discover).
case "$ENVIRONMENT" in
    "" | testnet | mainnet) ;;
    *)
        err "BAD_ARG: ENVIRONMENT='$ENVIRONMENT' - use testnet or mainnet, or leave it unset for both"
        exit 3
        ;;
esac

# The spec constrains chainSelector to ^[0-9]+$; a non-numeric one is a 400 the operator would have
# to decode from the API's wording.
case "$CHAIN_SELECTOR" in
    "") ;;
    *[!0-9]*)
        err "BAD_ARG: CHAIN_SELECTOR='$CHAIN_SELECTOR' - must be the numeric chain selector (make discover lists them)"
        exit 3
        ;;
esac

query="reviewedOnly=false&expand=true&limit=1000"
[ -n "$ENVIRONMENT" ] && query="${query}&environment=${ENVIRONMENT}"
[ -n "$ADMIN" ] && query="${query}&admin=$(uri "$ADMIN")"
[ -n "$SYMBOL" ] && query="${query}&symbol=$(uri "$SYMBOL")"
[ -n "$CHAIN_SELECTOR" ] && query="${query}&chainSelector=${CHAIN_SELECTOR}"

body_file="$(mktemp)"
rows_file="$(mktemp)"
map_file="$(mktemp)"
cfg_file="$(mktemp)"
trap 'rm -f "$body_file" "$rows_file" "$map_file" "$cfg_file"' EXIT

fetch() { # fetch <url> - body into $body_file, exits 5 on anything but 200
    local code
    code="$(curl -sS --retry 3 --max-time 30 -o "$body_file" -w '%{http_code}' "$1" 2> /dev/null)" || {
        err "API_UNREACHABLE: could not reach $1 (network error/timeout after retries) - retry later or fix CCIP_API_BASE"
        exit 5
    }
    [ "$code" = "200" ] || {
        err "API_UNREACHABLE: HTTP ${code} from $1 - retry later"
        exit 5
    }
}

# selector -> selectorName, both planes in one GET (/chains takes only `environment` and does not page).
fetch "${BASE_URL}/chains"
jq -r '(if type == "array" then . else .chains end)[]
    | [(.chainSelector | tostring), .name] | @tsv' "$body_file" > "$map_file" || {
    err "BAD_BODY: ${BASE_URL}/chains answered 200 with a body this script cannot read"
    exit 6
}

# selector -> local config name (skip the gitignored zz-scratch-* test files)
for f in config/chains/*.json; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in zz-scratch-*) continue ;; esac
    jq -r '[(.chainSelector | tostring), .name] | @tsv' "$f"
done | awk -F'\t' '{ a[$1] = (a[$1] == "" ? $2 : a[$1] "," $2) } END { for (s in a) print s "\t" a[s] }' \
    > "$cfg_file"

cursor=""
pages=0
total=""
# A cursor that never clears would spin forever against a broken or mocked API; 1000/page makes 500
# pages a ceiling no real operator reaches.
while [ "$pages" -lt 500 ]; do
    url="${BASE_URL}/tokens?${query}"
    [ -n "$cursor" ] && url="${url}&cursor=$(uri "$cursor")"
    fetch "$url"
    pages=$((pages + 1))

    jq -r '.data[]
        | [(.chainSelector | tostring), .address, (.symbol // "-"), (.groupId // "-"),
           ([(.remoteChains // [])[] | select(.status == "CONNECTED")] | length | tostring)]
        | @tsv' "$body_file" >> "$rows_file" || {
        err "BAD_BODY: ${BASE_URL}/tokens answered 200 with a body this script cannot read"
        exit 6
    }

    [ -n "$total" ] || total="$(jq -r '.pagination.totalCount // "?"' "$body_file")"
    has_next="$(jq -r '.pagination.hasNextPage // false' "$body_file")"
    cursor="$(jq -r '.pagination.cursor // ""' "$body_file")"
    [ "$has_next" = "true" ] && [ -n "$cursor" ] || { cursor=""; break; }
done
# Truncation must never be silent - that is the same failure as the reviewedOnly default.
[ -z "$cursor" ] || err "WARNING: stopped at the ${pages}-page ceiling; the list below is INCOMPLETE - narrow it with ADMIN=/SYMBOL=/CHAIN_SELECTOR="

if [ -n "$POOL" ]; then
    detail_file="$(mktemp)"
    enriched="$(mktemp)"
    while IFS=$'\t' read -r sel addr sym grp lanes; do
        pool='?' ptype='?' pver='?'
        code="$(curl -sS --retry 2 --max-time 30 -o "$detail_file" -w '%{http_code}' \
            "${BASE_URL}/tokens/${sel}/${addr}" 2> /dev/null)" || code=""
        if [ "$code" = "200" ] && jq -e '.pool' "$detail_file" > /dev/null 2>&1; then
            pool="$(jq -r '.pool.address // "?"' "$detail_file")"
            ptype="$(jq -r '.pool.type // "?"' "$detail_file")"
            pver="$(jq -r '.pool.version // "?"' "$detail_file")"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sel" "$addr" "$sym" "$grp" "$lanes" "$pool" "$ptype" "$pver"
    done < "$rows_file" > "$enriched"
    mv "$enriched" "$rows_file"
    rm -f "$detail_file"
fi

rows="$(wc -l < "$rows_file" | tr -d ' ')"
scope="$([ -n "$ENVIRONMENT" ] && echo "$ENVIRONMENT" || echo "both planes")"
filters="$(printf '%s' "${ADMIN:+ADMIN=$ADMIN }${SYMBOL:+SYMBOL=$SYMBOL }${CHAIN_SELECTOR:+CHAIN_SELECTOR=$CHAIN_SELECTOR }")"

if [ "$rows" -eq 0 ]; then
    echo "No tokens match (${scope}${filters:+, ${filters% }})."
    echo ""
    echo "This is a normal answer, not a failure: the API lists a token only once its mesh is fully"
    echo "configured, so a token still being wired through this repo is legitimately absent. Nothing"
    echo "is wrong with your setup."
    echo ""
    echo "  widen it:  drop ADMIN/SYMBOL/CHAIN_SELECTOR, or leave ENVIRONMENT unset to list both planes"
    echo "  manual:    make adopt-token CHAIN=<name> TOKEN=<addr> POOL=<addr>   (record what you already have)"
    echo "             make deploy-new-chain CHAIN=<name> SELECTOR=<sel>        (deploy a new one)"
    exit 0
fi

{
    if [ -n "$POOL" ]; then
        printf 'CHAIN SELECTOR\tCHAIN\tTOKEN\tSYMBOL\tGROUP\tLANES\tPOOL\tPOOL TYPE\tPOOL VERSION\tLOCAL CONFIG\n'
    else
        printf 'CHAIN SELECTOR\tCHAIN\tTOKEN\tSYMBOL\tGROUP\tLANES\tLOCAL CONFIG\n'
    fi
    awk -F'\t' -v OFS='\t' -v names="$map_file" -v cfgs="$cfg_file" '
        FILENAME == names { nm[$1] = $2; next }
        FILENAME == cfgs  { cfg[$1] = $2; next }
        {
            local_cfg = ($1 in cfg ? "configured(" cfg[$1] ")" : "no local config")
            if (NF >= 8) print $1, ($1 in nm ? nm[$1] : "?"), $2, $3, $4, $5, $6, $7, $8, local_cfg
            else print $1, ($1 in nm ? nm[$1] : "?"), $2, $3, $4, $5, local_cfg
        }
    ' "$map_file" "$cfg_file" "$rows_file" | sort
} | column -t -s "$(printf '\t')"

echo ""
echo "${rows} token(s) listed (API totalCount ${total}, ${pages} page(s), ${scope}${filters:+, ${filters% }})."
if awk -F'\t' -v cfgs="$cfg_file" 'FILENAME == cfgs { cfg[$1]; next } !($1 in cfg) { n++ } END { exit !(n > 0) }' "$cfg_file" "$rows_file"; then
    echo "Rows marked 'no local config' need their chain onboarded first:" \
        "make add-chain CHAIN=<CHAIN column> SELECTOR=<CHAIN SELECTOR column>"
fi
echo "raw: curl -s '${BASE_URL}/tokens?${query}' | jq"
