#!/usr/bin/env bash
# evm-version.sh <selectorName> [--lenient]
#
# Print the EVM version a forge run scoped to <selectorName> must use, so every caller (the Makefile
# recipes, roles-check, verify-contract) resolves it the same way from the same data.
#
# Resolution: the chain's optional `evmVersion` key in config/chains/<selectorName>.json, else the
# repo default. The default is READ FROM `forge config` rather than hardcoded, so it can never drift
# from `foundry.toml` - a run with no per-chain declaration then passes `--evm-version <the same value
# forge would have used anyway>`, which is a no-op by construction.
#
# Why the key exists at all: `foundry.toml` targets shanghai, whose PUSH0 opcode a few CCIP chains
# never activated. Bytecode compiled for shanghai is undeployable there, so those chains declare
# `"evmVersion": "paris"` and their runs compile down to what their network can execute. On a
# read-only path the same flag configures the local interpreter instead; that direction is harmless,
# because a chain that rejects PUSH0 cannot be hosting a contract that contains one.
#
# A DECLARED value must be one forge accepts, and this is where that is caught. Left unchecked, a typo
# reaches forge as `--evm-version parris` and every target dies on a CLI error about a flag the
# operator never typed, including `make doctor` - the one command whose job is to name schema problems.
#
# Exit-code contract:
#   0 - resolved (no key, unreadable file, unknown chain: the default; a valid key: its value)
#   3 - the key holds a value this repo does not recognize (diagnostic on stderr, nothing on stdout)
# `--lenient` turns the 3 into the default plus the same stderr diagnostic, for callers that must keep
# running so they can report the problem themselves. Read and diagnose paths pass it (`make doctor`
# then FAILs the schema rung by name, with the fix); paths that BROADCAST do not, so a typo can never
# quietly deploy default-version bytecode to a chain that pins another version.
set -uo pipefail
cd "$(dirname "$0")/../.."

name="${1:-}"
lenient=""
[ "${2:-}" = "--lenient" ] && lenient="1"

# The repo default, from forge itself (honors FOUNDRY_PROFILE). The literal is the last resort for an
# environment where `forge config` cannot run at all; it matches foundry.toml's [profile.default].
default="$(forge config --json 2> /dev/null | jq -r '.evm_version // empty' 2> /dev/null)"
[ -n "$default" ] || default="shanghai"

declared=""
file="config/chains/${name}.json"
if [ -n "$name" ] && [ -f "$file" ]; then
    # A file that does not parse is not a file with no declaration. Reading it as the latter would hand
    # the default to a broadcast that may have been pinned to another version, which is the one outcome
    # this resolver exists to prevent, so it is refused on the same terms as a bad value.
    if ! jq -e . "$file" > /dev/null 2>&1; then
        echo "[evm-version] ${file} is not valid JSON, so no evmVersion could be read from it." \
            "Fix the file, then: make doctor CHAIN=${name}" >&2
        if [ -n "$lenient" ]; then
            printf '%s\n' "$default"
            exit 0
        fi
        exit 3
    fi
    # `// empty` collapses absent, null and "" into the same answer, and only the first of those means
    # "this chain inherits the default". The other two are a broken declaration, which the schema rung
    # FAILs - so treating them as absent here would have the two disagree about the same file.
    if jq -e 'has("evmVersion")' "$file" > /dev/null 2>&1; then
        declared="$(jq -r '.evmVersion // ""' "$file")"
        if [ -z "$declared" ]; then
            echo "[evm-version] evmVersion in ${file} is empty or null. Give it a version" \
                "(london/paris/shanghai/cancun/prague/osaka) or remove the key to inherit the default," \
                "then: make doctor CHAIN=${name}" >&2
            if [ -n "$lenient" ]; then
                printf '%s\n' "$default"
                exit 0
            fi
            exit 3
        fi
    fi
fi

if [ -z "$declared" ]; then
    printf '%s\n' "$default"
    exit 0
fi

# The accepted set is the same one VerifyChain's schema rung names, so the two cannot disagree about
# what a valid declaration is.
case "$declared" in
    london | paris | shanghai | cancun | prague | osaka) ;;
    *)
        echo "[evm-version] '$declared' in config/chains/${name}.json is not an evmVersion this repo" \
            "recognizes (london/paris/shanghai/cancun/prague/osaka). Fix the key, then: make doctor CHAIN=${name}" >&2
        if [ -n "$lenient" ]; then
            printf '%s\n' "$default"
            exit 0
        fi
        exit 3
        ;;
esac

printf '%s\n' "$declared"
