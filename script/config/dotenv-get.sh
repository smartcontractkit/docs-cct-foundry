#!/usr/bin/env bash
# dotenv-get.sh <KEY>: print the value of one variable, environment first, `./.env` filling the gap.
# Prints nothing (exit 0) when neither has it - callers decide whether absence is an error.
#
# Why this exists: `.env` here is plain `KEY=VALUE` with no `export`, so `source .env` sets SHELL
# variables. `printenv` and `${!var}` read the ENVIRONMENT and never see them. Forge-based targets are
# unaffected because Foundry loads `.env` itself; every shell-based one broke, and the README told
# users to do the thing that cannot work. One resolver for every caller, the same shape as
# `evm-version.sh`.
#
# It READS the file rather than sourcing it, and exports nothing. That is deliberate, not caution for
# its own sake: these scripts hand their environment to `ccip-cli`, whose parser maps every `CCIP_*`
# variable to an option and exits nonzero on one it does not know (`.env.example` ships a commented-out
# `CCIP_API_BASE`, which becomes `--api-base`). A blanket `set -a; . .env` would turn a documented
# config line into a failed preflight. The CLI also adopts an ambient `PRIVATE_KEY` as the sender, and
# the sender changes the allowlist answer.
#
# Precedence is environment-wins, matching Foundry's own non-overriding dotenv and this repo's
# `roles-check.sh`. A variable that is SET BUT EMPTY counts as set: the Makefile avoids exporting empty
# strings for exactly that reason, so honouring the distinction keeps the two consistent.
set -uo pipefail

key="${1:-}"
[ -n "$key" ] || {
    echo "usage: dotenv-get.sh <KEY>" >&2
    exit 2
}

# `${!key+x}` is set-ness, not non-emptiness: an exported empty value still wins over the file.
if [ -n "${!key+x}" ]; then
    printf '%s' "${!key}"
    exit 0
fi

env_file="${DOTENV_FILE:-$(dirname "$0")/../../.env}"
[ -r "$env_file" ] || exit 0

# `|| [ -n "$line" ]` so a final line with no trailing newline is still read.
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                          # CRLF
    line="${line#"${line%%[![:space:]]*}"}"       # leading whitespace
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
        export\ *)
            line="${line#export }"
            line="${line#"${line%%[![:space:]]*}"}"
            ;;
    esac
    [ "${line%%=*}" = "$key" ] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
        \"*\") value="${value#\"}" value="${value%\"}" ;;
        \'*\') value="${value#\'}" value="${value%\'}" ;;
        *)
            value="${value%%[[:space:]]#*}"           # unquoted trailing ` # comment`
            value="${value%"${value##*[![:space:]]}"}" # trailing whitespace
            ;;
    esac
    found="$value" # keep scanning: last assignment wins, as dotenv does
done < "$env_file"

printf '%s' "${found:-}"
