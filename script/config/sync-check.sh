#!/usr/bin/env bash
# sync-check.sh [chain ...] — READ-ONLY config drift check, wrapping SyncCcipConfig.check(string).
#
# With no args, checks EVERY config/chains/*.json (non-EVM files SKIP inside Solidity).
# Classifies the forge output into a CI-ready exit-code contract (owned by THIS script — callers
# such as the scheduled workflow rely on it):
#   0  CLEAN            every checked chain's ccip{} matches the live API
#   1  CONFIG_DRIFT     at least one chain drifted (or a real config error, e.g. NOT_FOUND selector)
#   2  API_UNREACHABLE  the API could not be reached for at least one chain and NOTHING drifted
#                       (flake, not drift — CI should warn-and-pass, never go red on this)
#
# The sync path reads no secret, so a missing .env is tolerated (CI has none).
set -uo pipefail

cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
[ -f ./.env ] && { set -a && source ./.env && set +a; }

chains=("$@")
if [ ${#chains[@]} -eq 0 ]; then
    for f in config/chains/*.json; do
        base="$(basename "$f" .json)"
        # Skip the gitignored zz-scratch-* files the test suites write here (fake selectors).
        case "$base" in zz-scratch-*) continue ;; esac
        chains+=("$base")
    done
fi

drift=0
unreachable=0
declare -a drifted=() flaked=()

for name in "${chains[@]}"; do
    echo ">> sync-check $name"
    out="$(FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "check(string)" "$name" 2>&1)"
    status=$?
    echo "$out" | grep -E "DRIFT |SKIP |CLEAN |SELECTOR MISMATCH|API_UNREACHABLE|NOT_FOUND|CONFIG_DRIFT" || true
    if [ $status -ne 0 ]; then
        if echo "$out" | grep -q "API_UNREACHABLE"; then
            unreachable=1
            flaked+=("$name")
        else
            drift=1
            drifted+=("$name")
        fi
    fi
done

if [ $drift -ne 0 ]; then
    echo "sync-check: CONFIG_DRIFT (or config error) for: ${drifted[*]} - refresh with:" \
        "FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" <name>"
    exit 1
elif [ $unreachable -ne 0 ]; then
    echo "sync-check: API_UNREACHABLE for: ${flaked[*]} - flake, not drift; retry later"
    exit 2
fi
echo "sync-check: CLEAN - no drift against the live API"
exit 0
