#!/usr/bin/env bash
# roles-check.sh [chain ...] — READ-ONLY authority reconcile wrapper around RolesCheck.run(string).
#
# Scoped by token group: GROUP/PROJECT_GROUP selects one; unset scans the default (flat) group AND every
# project/<group>/ subdirectory, labelling each result line with its group. With no chain args it checks
# every EVM chain whose group project store (project/[<group>/]<name>.json) DECLARES a roles{} block
# (chains without one are listed as SKIP — bootstrap them with `make snapshot-chain CHAIN=<name>`). Chain
# family comes from config/chains; the declared roles{} lives in the project store. Classifies the forge
# output into the CI-ready exit-code contract (the contract belongs to THIS SCRIPT — GNU make remaps any
# recipe failure to exit 2, so `make roles-check` is pass/fail only; CI calls the script directly, the
# same lesson as sync-check.sh):
#   0  CLEAN            every checked chain's declared roles{} matches the live chain
#   1  ROLES_DRIFT      at least one declared holder/config mismatches (or a real config error)
#   2  RPC_UNAVAILABLE  an RPC was unset/unreachable for at least one chain and NOTHING drifted
#                       (flake/missing secret, not drift — CI should warn-and-pass, never go red)
set -uo pipefail

cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
[ -f ./.env ] && { set -a && source ./.env && set +a; }

# project store path for (group, chain); empty group = the flat default group.
group_file() { if [ -z "$1" ]; then echo "project/$2.json"; else echo "project/$1/$2.json"; fi; }
group_label() { if [ -z "$1" ]; then echo "default"; else echo "$1"; fi; }

requested_group="${PROJECT_GROUP:-}"

# An explicit group must be a valid name AND exist, else a typo (e.g. GROUP=usdxx) would find no files,
# skip every chain, and report a false CLEAN (exit 0) for a token whose roles were never checked.
if [ -n "$requested_group" ]; then
    if ! printf '%s' "$requested_group" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
        echo "roles-check: invalid token-group name '$requested_group' - use [a-z0-9][a-z0-9-]*"
        exit 1
    fi
    if [ ! -d "project/$requested_group" ]; then
        existing="$(cd project 2>/dev/null && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')"
        echo "roles-check: unknown token group '$requested_group' (no project/$requested_group/) - existing groups: ${existing:-<none>}"
        exit 1
    fi
fi

# Groups to scan: an explicit PROJECT_GROUP wins; otherwise the default group plus every non-scratch
# project/<group>/ subdirectory.
declare -a groups=()
if [ -n "$requested_group" ]; then
    groups=("$requested_group")
else
    groups=("")
    for d in project/*/; do
        [ -d "$d" ] || continue
        g="$(basename "$d")"
        case "$g" in zz-scratch-*) continue ;; esac
        groups+=("$g")
    done
fi

# Build the (group, chain) work list. Explicit chain args stay in the requested (or default) group; with
# no args, discover every chain that DECLARES roles{} in each scanned group.
declare -a pair_group=() pair_chain=()
if [ "$#" -gt 0 ]; then
    for name in "$@"; do
        pair_group+=("$requested_group")
        pair_chain+=("$name")
    done
else
    for g in "${groups[@]}"; do
        for f in config/chains/*.json; do
            name="$(basename "$f" .json)"
            # Skip the gitignored zz-scratch-* files the test suites write here (fake selectors).
            case "$name" in zz-scratch-*) continue ;; esac
            if [ "$(jq -r '.chainFamily' "$f")" != "evm" ]; then
                echo ">> roles-check [group: $(group_label "$g")] $name: SKIP (non-EVM)"
                continue
            fi
            pf="$(group_file "$g" "$name")"
            if [ ! -f "$pf" ] || [ "$(jq -r '(.roles // {}) | has("token")' "$pf" 2>/dev/null)" != "true" ]; then
                hint="make snapshot-chain CHAIN=$name"
                [ -n "$g" ] && hint="$hint GROUP=$g"
                echo ">> roles-check [group: $(group_label "$g")] $name: SKIP (no roles{} declared - $hint)"
                continue
            fi
            pair_group+=("$g")
            pair_chain+=("$name")
        done
    done
fi

if [ ${#pair_chain[@]} -eq 0 ]; then
    echo "roles-check: CLEAN - no chain declares a roles{} block yet (bootstrap with make snapshot-chain)"
    exit 0
fi

drift=0
unreachable=0
reconciled=0
declare -a drifted=() flaked=()

for i in "${!pair_chain[@]}"; do
    g="${pair_group[$i]}"
    name="${pair_chain[$i]}"
    label="$(group_label "$g")"
    echo ">> roles-check [group: $label] $name"
    # No FOUNDRY_PROFILE=sync here (unlike sync-check.sh): RolesCheck is read-only and needs no ffi; the
    # default profile already grants the fs read it uses. PROJECT_GROUP selects the group's project store.
    out="$(PROJECT_GROUP="$g" forge script script/config/RolesCheck.s.sol --sig "run(string)" "$name" 2>&1)"
    status=$?
    echo "$out" | grep -q "NO_ROLES_DECLARED" || reconciled=$((reconciled + 1))
    matched="$(echo "$out" | grep -E "\[PASS\]|\[FAIL\]|\[WARN\]|\[SKIP\]|CLEAN|ROLES_DRIFT|RPC_UNAVAILABLE|NO_ROLES_DECLARED|unknown chain" || true)"
    if [ -n "$matched" ]; then
        echo "$matched" | sed "s/^/[group: $label] /"
    elif [ $status -ne 0 ]; then
        # A revert (bad group, schema mismatch, ...) matches none of the markers - surface it, don't swallow.
        echo "$out" | tail -n 5 | sed "s/^/[group: $label] /"
    fi
    if [ $status -ne 0 ]; then
        if echo "$out" | grep -q "RPC_UNAVAILABLE"; then
            unreachable=1
            flaked+=("$label/$name")
        else
            drift=1
            drifted+=("$label/$name")
        fi
    fi
done

if [ $drift -ne 0 ]; then
    echo "roles-check: ROLES_DRIFT (or config error) for: ${drifted[*]} - remediate on-chain or re-declare via make snapshot-chain CHAIN=<name> [GROUP=<g>]"
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
