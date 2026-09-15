#!/usr/bin/env bash
# probe-chain.sh <chain>  -  READ-ONLY non-forking CCIP wiring read, wrapping ProbeChain.run(string).
#
# ProbeChain reports every rung instead of reverting on the first bad one, so it exits 0 while
# printing `[FAIL] router: NO CODE at 0x...`. This script turns that report into an exit code.
#
# Exit-code contract (owned by THIS script; callers and CI rely on it):
#   0  READABLE    every declared CCIP contract answered with code present
#   1  UNREADABLE  a declared contract has no code, or the endpoint answers as a different chain
#   2  UNRESOLVED  bad args, missing config, non-EVM chain, unset RPC, or the endpoint could not be
#                  reached  -  a tooling/transport problem, never evidence about the chain
#
# `make probe-chain` is pass/fail only: GNU make remaps any failing recipe to its own exit 2, which
# would collapse UNREADABLE and UNRESOLVED. CI calls this script directly (same reason as
# sync-check.sh and roles-check.sh).
set -uo pipefail

cd "$(dirname "$0")/../.."

CHAIN="${1:-}"
if [ -z "$CHAIN" ]; then
    echo "usage: probe-chain.sh <chain>   (a config/chains/ file name, e.g. ethereum-testnet-sepolia)" >&2
    exit 2
fi

if ! command -v forge > /dev/null 2>&1; then
    echo "probe-chain: forge is required but not installed - https://book.getfoundry.sh/getting-started/installation" >&2
    exit 2
fi

if [ ! -f "config/chains/${CHAIN}.json" ]; then
    echo "probe-chain: unknown chain '${CHAIN}' - no config/chains/${CHAIN}.json (new chain? make add-chain CHAIN=<selectorName> SELECTOR=<selector>)" >&2
    exit 2
fi

# The forge run autoloads ./.env for the chain's rpcEnv without overriding the ambient environment.
out="$(FOUNDRY_PROFILE=sync forge script script/config/ProbeChain.s.sol --tc ProbeChain --sig "run(string)" "$CHAIN" 2>&1)"
status=$?
echo "$out"

if [ $status -ne 0 ]; then
    # The only revert that is evidence ABOUT the chain: the endpoint answered, as something else.
    # Matched on the token ProbeChain puts FIRST in that one revert reason, anchored to forge's own
    # `Error: script failed:` prefix. A bare substring match reads whatever forge echoes back,
    # including the chain name, so a config named after the message could forge this verdict.
    if grep -Eq "^Error: script failed: PROBE_WRONG_CHAIN: " <<< "$out"; then
        echo "probe-chain: UNREADABLE - $CHAIN's RPC answers for a different chain"
        exit 1
    fi
    echo "probe-chain: UNRESOLVED - the probe did not complete for $CHAIN (see above); nothing was learned about the chain"
    exit 2
fi

# `== probe-chain <name>: N ok, M unreadable ==`, printed only by a completed run. Not anchored
# at line start: forge indents script logs by two spaces.
summary="$(grep -E "== probe-chain .*: [0-9]+ ok, [0-9]+ unreadable ==$" <<< "$out" | tail -1)"
if [ -z "$summary" ]; then
    echo "probe-chain: UNRESOLVED - the probe exited 0 without a summary line for $CHAIN"
    exit 2
fi
unreadable="$(sed -E 's/.*, ([0-9]+) unreadable ==$/\1/' <<< "$summary")"

if [ "$unreadable" -ne 0 ]; then
    echo "probe-chain: UNREADABLE - $unreadable declared contract(s) have no code on $CHAIN (see the [FAIL] lines above)"
    exit 1
fi
echo "probe-chain: READABLE - every declared CCIP contract answered on $CHAIN"
exit 0
