#!/usr/bin/env bash
# detect-evm-version.sh <selectorName>
#
# Decide whether a chain needs an `evmVersion` pin and record it in config/chains/<selectorName>.json.
# Run by `make add-chain` so a new chain arrives with the right answer, and available on its own
# (`make detect-evm-version CHAIN=<name>`) to re-check a chain already in the repo.
#
# What it is protecting against: the repo compiles for shanghai, whose PUSH0 opcode a few CCIP chains
# never activated. Bytecode built for shanghai is undeployable on those chains, and the failure lands
# at deploy time on a chain the operator probably cannot test cheaply. Detecting it from the chain
# itself is the difference between a fact anyone can observe and a list somebody has to remember.
#
# The probe is `eth_call --create`: it runs initcode in the node's own EVM, so it needs no funds, no
# keys and no gas, and it answers about the real network rather than about the repo's configuration.
#
# It writes ONLY the pin (`"evmVersion": "paris"`). A chain that supports PUSH0 gets no key, so the
# common case leaves the config exactly as the API generated it and inherits the repo default.
#
# Exit-code contract:
#   0 - measured. Either the pin was written, or PUSH0 is supported and nothing was needed.
#   4 - NOT measured (no RPC, unreachable, or the controls misbehaved). Nothing is written and the
#       reason goes to stderr. This is deliberately not a failure: it must not block adding a chain,
#       because refusing would be worse than inheriting the default. `make doctor` reports the gap.
set -uo pipefail
cd "$(dirname "$0")/../.."

name="${1:-}"
[ -n "$name" ] || {
    echo "[detect-evm-version] usage: detect-evm-version.sh <selectorName>" >&2
    exit 4
}

file="config/chains/${name}.json"
[ -f "$file" ] || {
    echo "[detect-evm-version] no config/chains/${name}.json - nothing to annotate" >&2
    exit 4
}

# The tools this needs, checked by name. Without this, a missing jq makes every read below return the
# empty string, which reads as "not an EVM chain" and exits 0 - a silent success that measured nothing.
for tool in jq cast; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "[detect-evm-version] ${name}: '${tool}' is not installed, so PUSH0 support was not" \
            "measured and no pin was written. Install it, then: make detect-evm-version CHAIN=${name}" >&2
        exit 4
    }
done

# Malformed JSON must not read as an absent key. `jq -r '.x // empty'` cannot tell the two apart, and
# treating "the file did not parse" as "the chain is fine" is how a wrong answer gets blessed.
jq -e . "$file" > /dev/null 2>&1 || {
    echo "[detect-evm-version] ${name}: ${file} is not valid JSON, so nothing about this chain could be" \
        "read and no pin was written. Fix the file, then: make detect-evm-version CHAIN=${name}" >&2
    exit 4
}

# Non-EVM families have no EVM opcodes to probe, so the question does not apply to them.
family="$(jq -r '.chainFamily // "evm"' "$file")"
if [ "$family" != "evm" ]; then
    exit 0
fi

rpc_env="$(jq -r '.rpcEnv // empty' "$file")"
if [ -z "$rpc_env" ]; then
    echo "[detect-evm-version] ${name}: ${file} declares no rpcEnv, so there is no endpoint to probe and" \
        "no pin was written. Add the key (make sync CHAIN=${name}), then:" \
        "make detect-evm-version CHAIN=${name}" >&2
    exit 4
fi
rpc="${!rpc_env:-}"
if [ -z "$rpc" ]; then
    echo "[detect-evm-version] ${name}: \$${rpc_env:-<none>} is not set, so PUSH0 support was not measured." \
        "The chain inherits the repo default. If this chain does not support PUSH0, set" \
        "\"evmVersion\": \"paris\" in ${file} by hand, or re-run with the RPC set:" \
        "make detect-evm-version CHAIN=${name}" >&2
    exit 4
fi

probe() { cast call --rpc-url "$rpc" --create "$1" 2> /dev/null; }

# Controls first. Without both behaving, a result means nothing: some nodes answer 0x for an invalid
# opcode, which would read as "PUSH0 supported" on a chain that rejects it.
if probe 0xfe > /dev/null 2>&1; then
    echo "[detect-evm-version] ${name}: the node accepted an INVALID opcode, so it cannot be probed" \
        "this way. PUSH0 support was NOT determined and no pin was written." >&2
    exit 4
fi
if [ "$(probe 0x60006000f3)" != "0x" ]; then
    echo "[detect-evm-version] ${name}: the paris-valid control did not run (endpoint unreachable or" \
        "rejecting eth_call). PUSH0 support was NOT determined and no pin was written." >&2
    exit 4
fi

# Guard against answering about the wrong network: public RPC directories carry chainId collisions,
# and a mismatched endpoint would otherwise pin this chain from another chain's opcode set. The guard
# refuses when it cannot run, rather than waving the probe through on an unidentified endpoint.
declared_id="$(jq -r '.chainId // empty' "$file")"
live_id="$(cast chain-id --rpc-url "$rpc" 2> /dev/null)"
if [ -z "$declared_id" ] || [ -z "$live_id" ]; then
    echo "[detect-evm-version] ${name}: could not confirm which chain \$${rpc_env} answers as" \
        "(declared '${declared_id:-<none>}', live '${live_id:-<unreachable>}'). Refusing to pin from an" \
        "unidentified endpoint. No pin was written." >&2
    exit 4
fi
if [ "$declared_id" != "$live_id" ]; then
    echo "[detect-evm-version] ${name}: \$${rpc_env} answers as chain ${live_id} but this config declares" \
        "${declared_id}. Refusing to pin from another chain's EVM. Fix the RPC, then:" \
        "make detect-evm-version CHAIN=${name}" >&2
    exit 4
fi

# PUSH0 PUSH0 RETURN: returns 0x where the opcode exists.
push0_out="$(cast call --rpc-url "$rpc" --create 0x5f5ff3 2>&1)"
if [ "$push0_out" = "0x" ]; then
    if [ "$(jq -r '.evmVersion // empty' "$file")" = "paris" ]; then
        echo "[detect-evm-version] ${name}: PUSH0 IS supported, but this config pins paris. Leaving the" \
            "pin in place - removing it would change the bytecode every future deploy produces. Delete" \
            "the evmVersion key by hand if the pin is genuinely obsolete." >&2
    fi
    exit 0
fi

# Anything else is NOT yet a rejection. A timeout, a rate limit or a malformed response also fail to
# return 0x, and pinning on absence-of-success writes a permanent paris pin from a transient blip -
# which silently returns the chain to the compile target this whole mechanism exists to move off.
# So require the node to SAY it rejected the opcode.
case "$push0_out" in
    *"invalid opcode"* | *"InvalidFEOpcode"* | *"not activated"* | *"NotActivated"*) ;;
    *)
        echo "[detect-evm-version] ${name}: the PUSH0 probe neither succeeded nor reported an invalid" \
            "opcode, so support was NOT determined and no pin was written. The node said:" \
            "${push0_out}" >&2
        exit 4
        ;;
esac

# Re-run the control after a rejection verdict. If the endpoint has meanwhile stopped serving eth_call,
# the rejection above says nothing about the opcode, and pinning on it would record a guess.
if [ "$(probe 0x60006000f3)" != "0x" ]; then
    echo "[detect-evm-version] ${name}: the PUSH0 probe reported an invalid opcode, but the paris-valid" \
        "control then stopped working, so the endpoint - not the opcode - is the likely cause. No pin" \
        "was written. Re-run when the endpoint is healthy: make detect-evm-version CHAIN=${name}" >&2
    exit 4
fi

# Same canonical form the Makefile's canon-chain-config applies to these files (sorted keys, 2-space
# indent, trailing newline kept), so annotating a chain does not show up as a formatting diff.
tmp="$(mktemp)"
jq --indent 2 -S '.evmVersion = "paris"' "$file" > "$tmp" && mv "$tmp" "$file"
echo "[detect-evm-version] ${name}: PUSH0 is REJECTED by this chain, so \"evmVersion\": \"paris\" was" \
    "recorded. Runs scoped to it will compile down to what the network can execute." >&2
exit 0
