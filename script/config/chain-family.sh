#!/usr/bin/env bash
# chain-family.sh <chain>: print the chain's declared chainFamily, lowercased and trimmed.
#
# Fails OPEN to `evm` when the chain is unknown, declares no family, or the file does not parse.
# Callers use this to REFUSE non-EVM work, so an unreadable file must never turn a working EVM path
# into a refusal; missing-config and schema errors belong to the targets that own them.
set -uo pipefail
cd "$(dirname "$0")/../.."

name="${1:-}"
file="config/chains/${name}.json"
if [ -z "$name" ] || [ ! -r "$file" ]; then
    printf 'evm\n'
    exit 0
fi

family="$(jq -r 'if (.chainFamily | type) == "string" then (.chainFamily | ascii_downcase | gsub("^\\s+|\\s+$"; "")) else empty end' "$file" 2> /dev/null)"
printf '%s\n' "${family:-evm}"
