#!/usr/bin/env bash
# ccip-chain-meta.sh <chainSelector>
#
# Fetch ONE chain's identity + metadata from the CCIP REST API v2 per-chain detail
# (`GET /chains/{selector}`), selected **by chainSelector** — the numeric identity key the whole
# stack shares. The per-selector endpoint carries the family-agnostic `chain{}` identity block AND
# the `chainMetadata{}` (explorer + native currency) block, so this single GET supplies every
# API-served field the sync maintains for BOTH EVM and non-EVM chains (the chain LIST endpoint has
# no `chainMetadata`). The config `name` carries the same canonical selectorName as the API `name`
# (e.g. "ethereum-testnet-sepolia-mantle-1"), but the join stays on the immutable selector.
#
# Emits a flat JSON row on stdout (all values strings; chainFamily lowercased to match the repo
# schema):
#   { apiName, displayName, chainFamily, environment, chainId, chainSelector,
#     explorerUrl, nativeCurrencySymbol }
# plus, for NON-EVM families only, the native address plane the EVM-typed `ccip{}` block cannot hold:
#   { nativeChainId, native: { router, rmnProxy, tokenAdminRegistry, registryModuleOwnerCustom,
#                              feeQuoter, link, tokenPoolPrograms: { burnMint, lockRelease } } }
# Every native key is a family-native STRING and every one is optional - see the transform below.
#
# Consumed by SyncCcipConfig.init() (add-chain), SyncCcipConfig.run()/check() on the NON-EVM path
# (EVM uses ccip-config-source.sh, which carries the same fields), and VerifyChain (the doctor's
# non-EVM selectorName rung) via vm.tryFfi — config-file generation stays Foundry-side
# (vm.serialize* + vm.writeFile / vm.writeJson); this script only fetches + selects.
#
# Spec (read it before changing a query): docs/reference/ccip-api.md
# Exit-code contract (stderr becomes the Solidity revert reason):
#   0 OK | 2 MISSING_TOOL | 4 NOT_FOUND (no chain for this selector) | 5 API_UNREACHABLE
set -euo pipefail

err() { echo "[ccip-chain-meta] $*" >&2; }

for tool in curl jq; do
    command -v "$tool" > /dev/null 2>&1 || {
        err "MISSING_TOOL: '$tool' not found on PATH - install it (e.g. brew install $tool)"
        exit 2
    }
done

SELECTOR="${1:?usage: ccip-chain-meta.sh <chainSelector>}"
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
        err "NOT_FOUND: no chain for selector ${SELECTOR} - run script/config/sync-discover.sh to list valid selectors"
        exit 4
        ;;
    *)
        err "API_UNREACHABLE: HTTP ${http_code} from ${BASE_URL}/chains/${SELECTOR} - retry later"
        exit 5
        ;;
esac

# `native{}` + `nativeChainId` are emitted for NON-EVM families only: they carry the chain's own
# address encoding (base58 on SVM, 32-byte hex on Aptos, never parseable as an EVM address), so they
# are a sibling plane to `ccip{}`, not a replacement for it. Key names mirror the `ccip{}` block where
# the concept is shared (rmn -> rmnProxy, registryModule -> registryModuleOwnerCustom); a key the API
# does not serve for this family is ABSENT, not zero - the families differ in which contracts exist
# (SVM has tokenPoolPrograms and no tokenAdminRegistry; Aptos has tokenAdminRegistry and no
# registryModule), and an absent key says "not a thing here" where a zero would say "missing".
# pick() prefers an ACTIVE entry but falls back to the first one, exactly as the EVM act() does: an
# inactive row is still the chain's address, and refusing it would diverge from the EVM path.
jq -c '
  def pick(a): ((a // []) | ((map(select(.isActive == true))[0]) // .[0]) | (.address? // null));
  (((.chain.chainFamily // "EVM") | ascii_downcase)) as $fam
  | .chainConfig as $c
  | (($c.tokenPoolPrograms // {})
     | {burnMint: pick(.burnMint), lockRelease: pick(.lockRelease)}
     | with_entries(select(.value != null))) as $tpp
  | {
  apiName: (.chain.name // error("no .chain.name in API body")),
  displayName: (.chain.displayName // .chain.name // ""),
  chainFamily: $fam,
  environment: (.chain.environment // "testnet"),
  chainId: ((.chain.chainId // 0) | tostring),
  chainSelector: (.chain.chainSelector | tostring),
  explorerUrl: (.chainMetadata.explorer.url // ""),
  nativeCurrencySymbol: (.chainMetadata.nativeCurrency.symbol // ""),
  nativeChainId: (if $fam == "evm" then null else ((.chain.chainId // "") | tostring) end),
  native: (if $fam == "evm" then null else ({
    router: pick($c.router),
    rmnProxy: pick($c.rmn),
    tokenAdminRegistry: pick($c.tokenAdminRegistry),
    registryModuleOwnerCustom: pick($c.registryModule),
    feeQuoter: pick($c.feeQuoter),
    link: ((($c.feeTokens // []) | map(select(.tokenSymbol == "LINK")) | .[0].tokenAddress) // null),
    tokenPoolPrograms: (if ($tpp | length) > 0 then $tpp else null end)
  } | with_entries(select(.value != null))) end)
} | with_entries(select(.value != null))' "$body_file"
