#!/usr/bin/env bash
# forge-fork.sh <chain> -- <forge script args...>
#
# Runs a forge script that forks INTERNALLY, coping with two opposite forge 1.8.x behaviours that
# cannot both be satisfied by a fixed choice of flags:
#
#   * A chain forge types separately (Monad) REFUSES the internal fork unless the execution network was
#     named up front: "cannot create a `monad` fork with an EVM instantiated for `ethereum`"
#     (crates/evm/core/src/fork/multi.rs, require_endpoint_family_match). Passing --rpc-url fixes it.
#
#   * An OP-stack chain (Base, measured) PANICS when --rpc-url is passed - rc=134, an abort inside
#     op_revm - where the same run without the flag verifies cleanly.
#
# So the flag is a fallback, not a default: run without it, and re-run with it only on that one error.
# That ordering keeps the historical behaviour for every chain that already worked, and the retry costs
# nothing unless the family guard actually fires.
set -uo pipefail
cd "$(dirname "$0")/../.."

chain="${1:-}"
shift
[ "${1:-}" = "--" ] && shift

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

"$@" > "$out" 2>&1
status=$?
if [ $status -eq 0 ] || ! grep -q "fork with an EVM instantiated for" "$out"; then
    cat "$out"
    exit $status
fi

# The family guard fired. It is the one failure --rpc-url is known to fix, and only worth retrying when
# an endpoint actually resolves; without one the original error is the more useful thing to report.
rpc="$(bash script/config/rpc-url.sh "$chain")"
if [ -z "$rpc" ]; then
    cat "$out"
    exit $status
fi
"$@" --rpc-url "$rpc"
