#!/usr/bin/env bash
# roles-check.sh [chain ...] — READ-ONLY authority reconcile wrapper around RolesCheck.run(string).
#
# With no args, checks every EVM config/chains/*.json that DECLARES a roles{} block (chains without
# one are listed as SKIP — bootstrap them with `make snapshot-chain CHAIN=<name>`). Classifies the
# forge output into the CI-ready exit-code contract (the contract belongs to THIS SCRIPT — GNU make
# remaps any recipe failure to exit 2, so `make roles-check` is pass/fail only; CI calls the script
# directly, the same lesson as sync-check.sh):
#   0  CLEAN            every checked chain's declared roles{} matches the live chain
#   1  ROLES_DRIFT      at least one declared holder/config mismatches (or a real config error)
#   2  RPC_UNAVAILABLE  an RPC was unset/unreachable for at least one chain and NOTHING drifted
#                       (flake/missing secret, not drift — CI should warn-and-pass, never go red)
set -uo pipefail

cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
[ -f ./.env ] && { set -a && source ./.env && set +a; }

chains=("$@")
if [ ${#chains[@]} -eq 0 ]; then
    for f in config/chains/*.json; do
        name="$(basename "$f" .json)"
        # Skip the gitignored zz-scratch-* files the test suites write here (fake selectors).
        case "$name" in zz-scratch-*) continue ;; esac
        if [ "$(jq -r '.chainFamily' "$f")" != "evm" ]; then
            echo ">> roles-check $name: SKIP (non-EVM)"
            continue
        fi
        if [ "$(jq 'has("roles")' "$f")" != "true" ]; then
            echo ">> roles-check $name: SKIP (no roles{} declared - make snapshot-chain CHAIN=$name)"
            continue
        fi
        chains+=("$name")
    done
fi

if [ ${#chains[@]} -eq 0 ]; then
    echo "roles-check: CLEAN - no chain declares a roles{} block yet (bootstrap with make snapshot-chain)"
    exit 0
fi

drift=0
unreachable=0
declare -a drifted=() flaked=()

reconciled=0
for name in "${chains[@]}"; do
    echo ">> roles-check $name"
    # No FOUNDRY_PROFILE=sync here (unlike sync-check.sh): RolesCheck is read-only and needs no ffi;
    # the default profile already grants the fs read it uses. Kept explicit so the divergence is intentional.
    out="$(forge script script/config/RolesCheck.s.sol --sig "run(string)" "$name" 2>&1)"
    status=$?
    echo "$out" | grep -q "NO_ROLES_DECLARED" || reconciled=$((reconciled + 1))
    echo "$out" | grep -E "\[PASS\]|\[FAIL\]|\[WARN\]|\[SKIP\]|CLEAN|ROLES_DRIFT|RPC_UNAVAILABLE|NO_ROLES_DECLARED|unknown chain" || true
    if [ $status -ne 0 ]; then
        if echo "$out" | grep -q "RPC_UNAVAILABLE"; then
            unreachable=1
            flaked+=("$name")
        else
            drift=1
            drifted+=("$name")
        fi
    fi
done

if [ $drift -ne 0 ]; then
    echo "roles-check: ROLES_DRIFT (or config error) for: ${drifted[*]} - remediate on-chain or re-declare via make snapshot-chain CHAIN=<name>"
    exit 1
elif [ $unreachable -ne 0 ]; then
    echo "roles-check: RPC_UNAVAILABLE for: ${flaked[*]} - flake/missing secret, not drift; retry with the RPC env set"
    exit 2
fi
echo "roles-check: CLEAN - ${reconciled} chain(s) actually reconciled (declared authority matches the live chain)"
if [ "$reconciled" -eq 0 ]; then
    echo "roles-check: NOTE - no chain was actually reconciled (none declares roles{} yet); this CLEAN checked nothing"
fi
exit 0
