#!/usr/bin/env bash
# verify-args.sh - compose the forge verifier flags for one chain from config/chains/<name>.json.
#
# Usage: bash script/config/verify-args.sh <selectorName>
#
# Prints the flags to append to `forge script --broadcast --verify ...` (inline verification) or
# `forge verify-contract ...` (standalone backfill), driven by the optional hand-authored
# `verifier{type,url}` block:
#   no verifier{} block, or type "etherscan" -> prints nothing (bare --verify: forge resolves the
#       Etherscan v2 endpoint from the chain id it reads via --rpc-url, and warns + falls back to
#       Sourcify for a chain Etherscan v2 does not serve)
#   type "blockscout" -> --verifier blockscout --verifier-url <verifier.url>
#   type "sourcify"   -> --verifier sourcify
# Fails loudly (nonzero + a named error on stderr) on: a missing config file, a non-EVM chain, an
# unknown verifier.type, and blockscout without a verifier.url.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ $# -ne 1 ]; then
    echo "[verify-args] usage: bash script/config/verify-args.sh <selectorName>" >&2
    exit 1
fi

name="$1"
file="config/chains/${name}.json"
if [ ! -f "$file" ]; then
    echo "[verify-args] no ${file} - unknown chain '${name}'" >&2
    exit 1
fi

family="$(jq -r '.chainFamily // empty' "$file")"
if [ "$family" != "evm" ]; then
    echo "[verify-args] ${name} is not an EVM chain (chainFamily '${family}') - no forge-compatible explorer verification" >&2
    exit 1
fi

vtype="$(jq -r '.verifier.type // "etherscan"' "$file")"
case "$vtype" in
    etherscan)
        # Bare --verify: nothing to add. forge derives the Etherscan v2 endpoint from the chain.
        ;;
    blockscout)
        url="$(jq -r '.verifier.url // empty' "$file")"
        if [ -z "$url" ]; then
            echo "[verify-args] ${name}: verifier.type blockscout needs a verifier.url (the instance API endpoint, usually <explorerUrl>/api)" >&2
            exit 1
        fi
        printf -- '--verifier blockscout --verifier-url %s\n' "$url"
        ;;
    sourcify)
        printf -- '--verifier sourcify\n'
        ;;
    *)
        echo "[verify-args] ${name}: unknown verifier.type '${vtype}' - use etherscan, blockscout or sourcify" >&2
        exit 1
        ;;
esac
