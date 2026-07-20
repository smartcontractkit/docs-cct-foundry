#!/usr/bin/env bash
# ccip-config-source.sh <chainSelector>
#
# The CCIP REST API v2 config source (https://api.ccip.chain.link/v2): the fetch + transform half of
# the config-sync seam. GETs the per-chain detail (`GET /chains/{selector}`) and flattens
# `chainConfig` to the single ACTIVE (`isActive: true`) address per contract type, emitting a
# compact, normalized JSON object on stdout whose keys mirror the repo's `config/chains/<name>.json`
# `ccip{}` block. Foundry (script/config/SyncCcipConfig.s.sol) then parses this and writes the
# config file — JSON *file* generation stays Foundry-side; this script only fetches + selects.
#
# The flat JSON also carries `apiName` + `chainId` so the Solidity side can cross-check the local
# config's chainId against what the selector ACTUALLY resolves to (the SELECTOR MISMATCH guard), plus
# the API-served identity + metadata fields the sync now MAINTAINS alongside `ccip{}`:
# `displayName`, `chainFamily` (lowercased to match the repo schema), `environment` (from `.chain`),
# and `explorerUrl` / `nativeCurrencySymbol` (from `.chainMetadata.explorer.url` /
# `.chainMetadata.nativeCurrency.symbol`). The per-selector body carries all of these in one GET — no
# extra round-trip — so the sync can source EVERY API-served field from the API instead of by hand.
#
# Exit-code contract (consumed by CcipApiSource via vm.tryFfi — stderr becomes the revert reason):
#   0  OK (flat JSON on stdout)
#   2  MISSING_TOOL     curl or jq not installed
#   4  NOT_FOUND        HTTP 404 — no chain for this selector (typo'd .chainSelector)
#   5  API_UNREACHABLE  network error / timeout / 5xx (flake, NOT drift — retry later)
#   6  BAD_BODY         200 but chainConfig lacks an active entry (partial/unsupported chain)
#
# The API base URL can be overridden with the non-secret CCIP_API_BASE env var (see .env.example).
set -euo pipefail

err() { echo "[ccip-config-source] $*" >&2; }

for tool in curl jq; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH - install it (e.g. brew install $tool)"
        exit 2
    }
done

SELECTOR="${1:?usage: ccip-config-source.sh <chainSelector>}"
BASE_URL="${CCIP_API_BASE:-https://api.ccip.chain.link/v2}"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

http_code="$(curl -sS --retry 3 --max-time 30 -o "$body_file" -w '%{http_code}' \
    "${BASE_URL}/chains/${SELECTOR}" 2> /dev/null)" || {
    err "API_UNREACHABLE: could not reach ${BASE_URL}/chains/${SELECTOR} (network error/timeout after retries) - retry later or fix CCIP_API_BASE"
    exit 5
}

case "$http_code" in
    200) ;;
    404)
        err "NOT_FOUND: no chain for selector ${SELECTOR} - check .chainSelector in your config (script/config/sync-discover.sh lists valid selectors)"
        exit 4
        ;;
    *)
        err "API_UNREACHABLE: HTTP ${http_code} from ${BASE_URL}/chains/${SELECTOR} (server error/flake, not config drift) - retry later"
        exit 5
        ;;
esac

# Key mapping API -> repo schema: rmn -> rmnProxy, registryModule -> registryModuleOwnerCustom,
# link = the feeTokens entry with tokenSymbol "LINK".
#
# CORE vs OPTIONAL contracts. `act(k)` REQUIRES an active entry for the four contracts a token issuer
# needs to onboard a chain: router and rmn (the Risk Management Network proxy) to deploy a pool, and
# tokenAdminRegistry and registryModule to register the token. A chain missing any of these is not
# onboardable, so it fails loudly rather than have a zero written for a routing or security contract.
# `optAct(k)`/the `link` fallback emit the zero address for the rest - feeQuoter (fee quoting), the
# CCT-era tokenPoolFactory, and a LINK fee token - which are commonly absent on live testnets; the sync
# writes zero and the Solidity side logs a WARN (see _warnZeroedOptionalContracts) so the gap is visible.
# Trade-off: a renamed optional API key is indistinguishable from an absent one (writes zero silently);
# a renamed REQUIRED key still hard-fails, so a wholesale API shape change is always caught.
jq -c '
  def zero: "0x0000000000000000000000000000000000000000";
  .chainConfig as $c
  | def act(k): (($c[k] // []) | ((map(select(.isActive == true))[0]) // .[0])
      | (.address // error("no active \(k) entry in chainConfig")));
    def optAct(k): (($c[k] // []) | ((map(select(.isActive == true))[0]) // .[0])
      | (.address // zero));
  {
    apiName: (.chain.name // error("no .chain.name in API body")),
    chainId: ((.chain.chainId | tostring) // error("no .chain.chainId in API body")),
    displayName: (.chain.displayName // .chain.name // ""),
    chainFamily: ((.chain.chainFamily // "EVM") | ascii_downcase),
    environment: (.chain.environment // "testnet"),
    explorerUrl: (.chainMetadata.explorer.url // ""),
    nativeCurrencySymbol: (.chainMetadata.nativeCurrency.symbol // ""),
    router: act("router"),
    rmnProxy: act("rmn"),
    tokenAdminRegistry: act("tokenAdminRegistry"),
    registryModuleOwnerCustom: act("registryModule"),
    feeQuoter: optAct("feeQuoter"),
    tokenPoolFactory: optAct("tokenPoolFactory"),
    link: ((($c.feeTokens // []) | map(select(.tokenSymbol == "LINK")) | .[0].tokenAddress) // zero),
    feeTokens: [ (($c.feeTokens // [])[] | .tokenAddress) ]
  }
' "$body_file" || {
    err "BAD_BODY: chainConfig for selector ${SELECTOR} is missing a CORE active entry - router, rmn, tokenAdminRegistry or registryModule (see jq error above). This chain cannot be onboarded yet; 'make discover' lists valid selectors"
    exit 6
}
