#!/usr/bin/env bash
# rpc-url.sh <chain>: print the chain's resolved RPC URL, or nothing.
#
# Callers pass the result to `forge script --rpc-url`. That flag is not about convenience: forge 1.8.x
# types the EVM by execution network, and a script that only forks INTERNALLY (vm.createSelectFork with
# no --rpc-url on the CLI) boots as generic `ethereum` and is then refused when it retargets -
# `cannot create a 'monad' fork with an EVM instantiated for 'ethereum'`
# (crates/evm/core/src/fork/multi.rs: require_endpoint_family_match). Naming the endpoint up front
# makes the network an explicit selection instead of an inference, and the guard no longer fires.
#
# Prints NOTHING when the chain declares no rpcEnv, or the variable is unset, or the chain is non-EVM.
# Callers must therefore omit the flag entirely rather than pass an empty one: the read targets are
# designed to degrade to a clean SKIP without an RPC, and an empty --rpc-url would turn that into a
# forge CLI error instead.
set -uo pipefail
cd "$(dirname "$0")/../.."

name="${1:-}"
[ -n "$name" ] || exit 0
file="config/chains/$name.json"
[ -r "$file" ] || exit 0

# Non-EVM chains are read by their own tooling; forge would reject the endpoint.
family="$(jq -r '.chainFamily // empty' "$file" 2> /dev/null)"
[ "$family" = "evm" ] || exit 0

env_name="$(jq -r '.rpcEnv // empty' "$file" 2> /dev/null)"
[ -n "$env_name" ] || exit 0
bash "$(dirname "$0")/dotenv-get.sh" "$env_name"
