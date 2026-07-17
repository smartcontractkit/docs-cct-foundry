#!/usr/bin/env bash
# test-tooling.sh — re-runnable failure-path + fixture tests for the chain-config tooling.
#
# These guards are the point of the tooling: every failure must be FAST and self-explaining (never a
# raw cheatcode revert), and the happy paths must be no-op-safe. Uses a throwaway config file
# (config/chains/tooling-tmp.json, cleaned up on exit) — never mutates the real chain files.
# Network cases hit the live CCIP API (read-only); API-down is simulated via CCIP_API_BASE; the
# sync TRANSFORM cases run fully offline against the committed API fixture
# (test/fixtures/ccip-api/) served by a local python3 http.server.
#
# Run from the repo root: bash script/config/test-tooling.sh
#
# PARTITIONS (TOOLING_PARTITION env): `offline` runs only the cases that need no live CCIP API (guards,
# make-arg preflights, the local-fixture-server sync, the canonical-format checks, and the committed-tree
# gates) — the fast PR-blocking set. `live` runs only the cases that reach the real API (selector/drift
# resolution, sync-check, the API-fetching doctor rungs) — the scheduled set. `all` (default) runs both.
set -uo pipefail

cd "$(dirname "$0")/../.."

PARTITION="${TOOLING_PARTITION:-all}"

TMP_CHAIN="tooling-tmp"
TMP_FILE="config/chains/${TMP_CHAIN}.json"
PROJECT_FILE="project/${TMP_CHAIN}.json"
TMP_CHAIN_B="tooling-tmp-b"
TMP_FILE_B="config/chains/${TMP_CHAIN_B}.json"
PROJECT_FILE_B="project/${TMP_CHAIN_B}.json"
FIXTURE="test/fixtures/ccip-api/chain-16015286601757825753.json"
SEPOLIA_SELECTOR="16015286601757825753"
# Committed API body for solana-devnet: serves the non-EVM metadata fetch offline (section 12d).
SVM_FIXTURE="test/fixtures/ccip-api/chain-16423721717087811551.json"
SVM_META_SELECTOR="16423721717087811551"
# A real, non-bundled chain used by the add-chain print-names case; its generated config is a
# throwaway removed on exit (never committed).
FUJI_CHAIN="avalanche-testnet-fuji"
FUJI_FILE="config/chains/${FUJI_CHAIN}.json"
FUJI_SELECTOR="14767482510784806043"
# Token groups: PROJECT_GROUP moves a chain's project file to
# project/<group>/<selectorName>.json. The env-driven group() is exercised here (a real GROUP=<g> make
# subprocess) since the in-process forge seam cannot set PROJECT_GROUP. Two gitignored scratch group
# DIRECTORIES (project/zz-scratch-*/), the two roles-check group dirs (project/zz-tt-ga, project/zz-tt-gb), and a
# non-EVM scratch chain for the base58 adopt path — all listed in cleanup() FIRST so a mid-test revert
# never strands a group dir (invisible to git status, would poison a later group scan).
GRP_X="zz-scratch-grp-x"
GRP_Y="zz-scratch-grp-y"
SVM_CHAIN="zz-scratch-svm-grp"
SVM_FILE="config/chains/${SVM_CHAIN}.json"
# Planted fixtures for the `make clean-scratch` case (19b); all four are in cleanup()'s rm-list.
CLEANX_PROJECT="project/zz-scratch-cleanx.json"
CLEANX_CONFIG="config/chains/zz-scratch-cleanx.json"
CLEANX_GRPDIR="project/zz-scratch-cleanx-grp"
CLEANX_HISTDIR="history/tokens/zz-scratch-cleanx"
pass=0
fail=0
declare -a failures=()
server_pid=""
server_dir=""
# .env backup for the caller-env-precedence case (13c): restored inline AND in cleanup() so a
# mid-case abort never leaves a mutated .env. env_planted=1 = case 13c wrote ./.env; env_bak is the
# pre-case copy (empty when .env did not exist).
env_planted=0
env_bak=""

restore_env() {
    if [ "$env_planted" = 1 ]; then
        if [ -n "$env_bak" ]; then mv "$env_bak" ./.env; else rm -f ./.env; fi
        env_planted=0
        env_bak=""
    fi
}

cleanup() {
    restore_env
    rm -f "$TMP_FILE" "$TMP_FILE_B" "$FUJI_FILE" "$PROJECT_FILE" "$PROJECT_FILE_B" "$SVM_FILE"
    rm -f "$CLEANX_PROJECT" "$CLEANX_CONFIG"
    rm -rf "$CLEANX_GRPDIR" "$CLEANX_HISTDIR"
    # Glob both scratch group-dir classes so a mid-test revert never strands one (invisible to git status).
    rm -rf project/zz-scratch-*/ project/zz-tt-*/ "project/$GRP_X" "project/$GRP_Y" "project/$SVM_CHAIN.json"
    [ -n "$server_pid" ] && kill "$server_pid" 2> /dev/null
    [ -n "$server_dir" ] && rm -rf "$server_dir"
}
trap cleanup EXIT

# Partition gates: an offline case is skipped under PARTITION=live; a live case under PARTITION=offline.
offline_enabled() { [ "$PARTITION" != live ]; }
live_enabled() { [ "$PARTITION" != offline ]; }

# Generous per-case timeout: a wedged case (hung fetch, stuck server) fails as a named TIMEOUT
# instead of hanging the whole suite. Skipped where no timeout tool exists (stock macOS).
TIMEOUT_TOOL=""
if command -v timeout > /dev/null 2>&1; then
    TIMEOUT_TOOL="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
    TIMEOUT_TOOL="gtimeout"
fi
# Both branches route through env(1): it consumes VAR=val prefixes then execs the real program, so
# a `FOUNDRY_PROFILE=sync forge ...` case works identically with and without a timeout tool
# (`timeout` alone would try to exec the program "FOUNDRY_PROFILE=sync" - ENOENT). Consequence:
# _run_case commands are EXEC'd, never shell-interpreted - shell functions cannot be passed to it.
_with_timeout() {
    if [ -n "$TIMEOUT_TOOL" ]; then "$TIMEOUT_TOOL" 600 env "$@"; else env "$@"; fi
}

# _run_case <name> <expected: zero|nonzero> <grep-pattern> -- <cmd...>
_run_case() {
    local name="$1" expect="$2" pattern="$3"
    shift 4 # name expect pattern --
    local out status
    out="$(_with_timeout "$@" 2>&1)"
    status=$?
    if [ -n "$TIMEOUT_TOOL" ] && [ $status -eq 124 ]; then
        fail=$((fail + 1))
        failures+=("$name")
        echo "[FAIL] $name (TIMEOUT after 600s)"
        return
    fi
    local ok=1
    if [ "$expect" = "zero" ] && [ $status -ne 0 ]; then ok=0; fi
    if [ "$expect" = "nonzero" ] && [ $status -eq 0 ]; then ok=0; fi
    if ! grep -q -- "$pattern" <<< "$out"; then ok=0; fi
    if [ $ok -eq 1 ]; then
        pass=$((pass + 1))
        echo "[PASS] $name"
    else
        fail=$((fail + 1))
        failures+=("$name")
        echo "[FAIL] $name (exit=$status, expected $expect + /$pattern/)"
        echo "$out" | tail -8 | sed 's/^/       | /'
    fi
}

# Offline case (needs no live API): runs in the `offline` and `all` partitions.
run_case() { offline_enabled && _run_case "$@"; }
# Live case (reaches the real CCIP API): runs in the `live` and `all` partitions.
run_case_live() { live_enabled && _run_case "$@"; }

# Direct $( ) capture only - a shell function cannot be exec'd by _with_timeout's env/timeout, so
# _run_case call sites spell the full command instead.
sync_script() {
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol "$@"
}

echo "== test-tooling: chain-config tooling failure-path + fixture suite =="

# ---------------------------------------------------------------- guards (no network)

# 1. unknown chain -> helpful list of configured chains, never a raw cheatcode revert
run_case "sync unknown chain lists known chains" nonzero "Known chains:" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" doesnotexist

# 2. direct invocation without the sync profile -> profile guard with the real fix
run_case "profile guard names the sync profile" nonzero "FOUNDRY_PROFILE=sync" -- \
    forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" ethereum-testnet-sepolia

# 3. add-chain refuses to overwrite an existing config
run_case "add-chain refuses to overwrite an existing config" nonzero "already exists - refusing to overwrite" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "init(string,uint256)" ethereum-testnet-sepolia "$SEPOLIA_SELECTOR"

# 4. chain names become file paths + shell args: unsafe names are refused up front
run_case "add-chain rejects a path-traversal name" nonzero "invalid chain name" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "init(string,uint256)" "../evil" "$SEPOLIA_SELECTOR"
run_case "add-chain rejects a name with a space" nonzero "invalid chain name" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "init(string,uint256)" "evil name" "$SEPOLIA_SELECTOR"

# 5. non-EVM SKIP: moved to section 12d (the non-EVM run/check paths also fetch identity metadata,
#    so the offline partition serves it from the committed solana-devnet fixture).

# ---------------------------------------------------------------- live API (read-only)

# 6. wrong-but-valid SELECTOR for an existing config -> SELECTOR MISMATCH naming both chainIds
cat > "$TMP_FILE" << 'EOF'
{
    "name": "tooling-tmp",
    "displayName": "Tooling test stub (throwaway)",
    "chainNameIdentifier": "TOOLING_TMP",
    "chainFamily": "evm",
    "environment": "testnet",
    "chainId": "99999",
    "chainSelector": "16015286601757825753",
    "rpcEnv": "TOOLING_TMP_RPC_URL",
    "confirmations": 2,
    "explorerUrl": "",
    "nativeCurrencySymbol": "",
    "ccip": {}
}
EOF
run_case_live "wrong selector -> SELECTOR MISMATCH naming both chainIds" nonzero \
    "SELECTOR MISMATCH for tooling-tmp: config says chainId 99999 but the selector resolves to chainId 11155111" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" "$TMP_CHAIN"

# 6b. right chainId+selector but a NON-canonical name -> SELECTOR NAME MISMATCH (the selectorName
#     guard: the config `name` must equal the CCIP registry/API selectorName). chainId matches so the
#     chainId guard passes and the NAME guard is the one that fires.
python3 -c "
import json
d = json.load(open('$TMP_FILE'))
d['chainId'] = '11155111'; d['name'] = 'ethereum-sepolia'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
run_case_live "non-canonical name -> SELECTOR NAME MISMATCH names the canonical selectorName" nonzero \
    "SELECTOR NAME MISMATCH for tooling-tmp: config name 'ethereum-sepolia' is not the canonical selectorName" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" "$TMP_CHAIN"

# 7. unknown selector -> NOT_FOUND from the fetch script, surfaced as the revert reason
python3 -c "
import json
d = json.load(open('$TMP_FILE')); d['chainSelector'] = '123'; json.dump(d, open('$TMP_FILE','w'), indent=4)
"
run_case_live "unknown selector -> named NOT_FOUND error" nonzero "NOT_FOUND: no chain for selector 123" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" "$TMP_CHAIN"
rm -f "$TMP_FILE"

# 7b. add-chain enforces the selectorName too: a non-canonical CHAIN name for a real selector fails
#     up front (this is the guard path that also validates non-EVM chains, whose chainId is "0").
run_case_live "add-chain rejects a non-canonical name -> SELECTOR NAME MISMATCH" nonzero \
    "SELECTOR NAME MISMATCH for ethereum-sepolia: config name 'ethereum-sepolia' is not the canonical selectorName" -- \
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "init(string,uint256)" ethereum-sepolia "$SEPOLIA_SELECTOR"

# 7c. add-chain PRINTS the exact derived env-var names so the operator never has to guess (or open
#     the JSON) which var to export. Uses a real, non-bundled chain (Fuji) whose UPPER_SNAKE-derived
#     AVALANCHE_TESTNET_FUJI differs from a curated short form; the generated config is a throwaway
#     removed here and in cleanup(). Asserts BOTH the chainNameIdentifier and the rpcEnv line.
if live_enabled; then
    rm -f "$FUJI_FILE"
    out="$(sync_script --sig "init(string,uint256)" "$FUJI_CHAIN" "$FUJI_SELECTOR" 2>&1)"
    if grep -q "chainNameIdentifier: AVALANCHE_TESTNET_FUJI" <<< "$out" &&
        grep -q "rpcEnv: *AVALANCHE_TESTNET_FUJI_RPC_URL" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] add-chain prints the generated chainNameIdentifier + rpcEnv names"
    else
        fail=$((fail + 1))
        failures+=("add-chain prints env-var names")
        echo "[FAIL] add-chain prints env-var names (missing chainNameIdentifier/rpcEnv line)"
        echo "$out" | tail -8 | sed 's/^/       | /'
    fi
    rm -f "$FUJI_FILE"
fi

# 8. API down (CCIP_API_BASE override) -> distinct API_UNREACHABLE error
run_case_live "API down -> named API_UNREACHABLE error" nonzero "API_UNREACHABLE" -- \
    env CCIP_API_BASE=http://127.0.0.1:1 bash -c \
    'FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" ethereum-testnet-sepolia-mantle-1'

# ---------------------------------------------------------------- sync-check exit contract (0/1/2)

# 9. clean chain -> exit 0 (live API)
run_case_live "sync-check clean chain exits 0" zero "CLEAN" -- \
    bash script/config/sync-check.sh ethereum-testnet-sepolia-mantle-1

# 10 + 11. drift (exit 1 + DRIFT line) and API-down (exit 2) on a throwaway COPY of sepolia.
if live_enabled; then
    python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['ccip']['router'] = '0x0000000000000000000000000000000000000001'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
    out="$(bash script/config/sync-check.sh "$TMP_CHAIN" 2>&1)"
    status=$?
    if [ $status -eq 1 ] && grep -q "DRIFT tooling-tmp .ccip.router" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] sync-check classifies drift as exit 1 + DRIFT line"
    else
        fail=$((fail + 1))
        failures+=("sync-check drift")
        echo "[FAIL] sync-check drift (exit=$status)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi

    out="$(CCIP_API_BASE=http://127.0.0.1:1 bash script/config/sync-check.sh "$TMP_CHAIN" 2>&1)"
    status=$?
    if [ $status -eq 2 ] && grep -q "API_UNREACHABLE" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] sync-check classifies API-down as exit 2"
    else
        fail=$((fail + 1))
        failures+=("sync-check api-down")
        echo "[FAIL] sync-check api-down (exit=$status)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    rm -f "$TMP_FILE"
fi

# ---------------------------------------------------------------- fixture transform (offline)

# Serve the committed API fixture from a local http.server so the REAL pipeline (curl + jq select +
# Solidity vm.writeJson) runs offline: GET /chains/<selector> -> the committed real response.
server_dir="$(mktemp -d)"
mkdir -p "$server_dir/chains"
cp "$FIXTURE" "$server_dir/chains/$SEPOLIA_SELECTOR"
cp "$SVM_FIXTURE" "$server_dir/chains/$SVM_META_SELECTOR"
port=$((20000 + RANDOM % 20000))
python3 -m http.server "$port" --directory "$server_dir" > /dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$port/chains/$SEPOLIA_SELECTOR" && break
    sleep 0.5
done

# 12. sync-config against the fixture server: ccip{} rewritten from the fixture's isActive entries,
#     every non-ccip key preserved, and a SECOND run leaves the file byte-identical (idempotency).
#     Local-fixture-server section (no live API): the whole section - sentinel setup, setup sync, and
#     the assertion blocks - shares the offline partition, so no partition ever runs an assertion
#     whose setup sync was skipped.
if offline_enabled; then
    python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['ccip'] = {'router': '0x0000000000000000000000000000000000000001',
             'rmnProxy': '0x0000000000000000000000000000000000000001',
             'tokenAdminRegistry': '0x0000000000000000000000000000000000000001',
             'registryModuleOwnerCustom': '0x0000000000000000000000000000000000000001',
             'link': '0x0000000000000000000000000000000000000001',
             'feeQuoter': '0x0000000000000000000000000000000000000001',
             'tokenPoolFactory': '0x0000000000000000000000000000000000000001',
             'feeTokens': []}
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
    run_case "fixture sync: run() succeeds against the local fixture server" zero "wrote .ccip block" -- \
        env CCIP_API_BASE="http://127.0.0.1:$port" bash -c \
        "FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig 'run(string)' $TMP_CHAIN"

    out="$(python3 -c "
import json
synced = json.load(open('$TMP_FILE'))
committed = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
# 1. ccip{} == the committed sepolia block (fixture is a real API response for the same chain)
assert synced['ccip'] == committed['ccip'], ('ccip mismatch', synced['ccip'])
# 2. every non-ccip key preserved verbatim (the throwaway keeps the committed canonical .name, so
#    the selectorName guard passes and nothing outside .ccip is touched)
for k, v in committed.items():
    if k == 'ccip':
        continue
    assert synced[k] == v, ('extra key mutated', k, synced[k], v)
print('TRANSFORM_OK')
" 2>&1)"
    if grep -q "TRANSFORM_OK" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] fixture sync: isActive selection + ccip-subtree-only write + extras preserved"
    else
        fail=$((fail + 1))
        failures+=("fixture transform")
        echo "[FAIL] fixture transform: $out"
    fi

    before="$(shasum "$TMP_FILE")"
    CCIP_API_BASE="http://127.0.0.1:$port" FOUNDRY_PROFILE=sync \
        forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" "$TMP_CHAIN" > /dev/null 2>&1
    after="$(shasum "$TMP_FILE")"
    if [ "$before" = "$after" ]; then
        pass=$((pass + 1))
        echo "[PASS] fixture sync: second run is idempotent (file byte-identical)"
    else
        fail=$((fail + 1))
        failures+=("fixture idempotency")
        echo "[FAIL] fixture sync: second run mutated the file"
    fi
fi

# 12b. API-served fields sourced from the API: a HAND-EDITED displayName/environment/explorerUrl/
#      nativeCurrencySymbol is CORRECTED to the API value on sync, while the genuinely hand-authored
#      keys (confirmations, rpcEnv, chainNameIdentifier) survive VERBATIM. This is the
#      one-writer-per-field guarantee for the widened synced surface. Local-fixture-server section:
#      setup and assertions share the offline partition (same rule as section 12).
if offline_enabled; then
    cat > "$TMP_FILE" << 'EOF'
{
  "name": "ethereum-testnet-sepolia",
  "displayName": "HAND WRONG NAME",
  "chainNameIdentifier": "CUSTOM_HAND_ID",
  "chainFamily": "evm",
  "environment": "mainnet",
  "chainId": "11155111",
  "chainSelector": "16015286601757825753",
  "rpcEnv": "CUSTOM_HAND_RPC_URL",
  "confirmations": 7,
  "explorerUrl": "http://hand.example/wrong",
  "nativeCurrencySymbol": "XXX",
  "ccip": {}
}
EOF
    run_case "sync sources API-served metadata from the API (corrects hand values)" zero "wrote .ccip block + metadata" -- \
        env CCIP_API_BASE="http://127.0.0.1:$port" bash -c \
        "FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig 'run(string)' $TMP_CHAIN"

    out="$(python3 -c "
import json
d = json.load(open('$TMP_FILE'))
api = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
# API-served fields are now the API's values, NOT the hand-edited ones
assert d['displayName'] == api['displayName'], ('displayName not sourced', d['displayName'])
assert d['environment'] == api['environment'], ('environment not sourced', d['environment'])
assert d['explorerUrl'] == api['explorerUrl'], ('explorerUrl not sourced', d['explorerUrl'])
assert d['nativeCurrencySymbol'] == api['nativeCurrencySymbol'], ('nativeCurrencySymbol not sourced', d['nativeCurrencySymbol'])
assert d['chainFamily'] == 'evm', ('chainFamily not normalized', d['chainFamily'])
# genuinely hand-authored keys survive verbatim
assert d['confirmations'] == 7, ('confirmations clobbered', d['confirmations'])
assert d['rpcEnv'] == 'CUSTOM_HAND_RPC_URL', ('rpcEnv clobbered', d['rpcEnv'])
assert d['chainNameIdentifier'] == 'CUSTOM_HAND_ID', ('chainNameIdentifier clobbered', d['chainNameIdentifier'])
print('SOURCE_OK')
" 2>&1)"
    if grep -q "SOURCE_OK" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] sync sources API-served fields + preserves hand-authored keys verbatim"
    else
        fail=$((fail + 1))
        failures+=("metadata sourcing")
        echo "[FAIL] metadata sourcing: $out"
    fi
fi

# 12c. drift in an API-served metadata field is caught by sync-check (exit 1 + DRIFT line), same
#      contract as ccip{} address drift.
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['explorerUrl'] = 'https://tampered.example'
json.dump(d, open('$TMP_FILE','w'), indent=2)
"
out="$(CCIP_API_BASE="http://127.0.0.1:$port" bash script/config/sync-check.sh "$TMP_CHAIN" 2>&1)"
status=$?
if [ $status -eq 1 ] && grep -q "DRIFT tooling-tmp .explorerUrl" <<< "$out"; then
    pass=$((pass + 1))
    echo "[PASS] sync-check catches metadata drift (.explorerUrl) as exit 1 + DRIFT line"
else
    fail=$((fail + 1))
    failures+=("metadata drift check")
    echo "[FAIL] metadata drift check (exit=$status, expected 1 + /DRIFT tooling-tmp .explorerUrl/)"
    echo "$out" | tail -6 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE"

# 12d. non-EVM chain -> Solidity-side SKIP of the EVM ccip{} transform (covers every entrypoint),
#      exit 0. The run/check paths ALSO fetch identity metadata, so the fixture server serves the
#      committed solana-devnet API body (chain-16423721717087811551.json) - the cases stay genuinely
#      network-free. The committed config's metadata matches the fixture, so the refresh is a no-op:
#      through `make sync` (which re-canonicalizes vm.writeJson's output - the raw forge run alone
#      drops the trailing newline) the file must survive byte-identical.
if offline_enabled; then
    svm_before="$(shasum config/chains/solana-devnet.json)"
    run_case "sync on a non-EVM chain SKIPs cleanly" zero "SKIP solana-devnet - chainFamily svm" -- \
        env CCIP_API_BASE="http://127.0.0.1:$port" make sync CHAIN=solana-devnet
    run_case "check on a non-EVM chain SKIPs cleanly" zero "SKIP solana-devnet - chainFamily svm" -- \
        env CCIP_API_BASE="http://127.0.0.1:$port" bash -c \
        "FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig 'check(string)' solana-devnet"
    svm_after="$(shasum config/chains/solana-devnet.json)"
    if [ "$svm_before" = "$svm_after" ]; then
        pass=$((pass + 1))
        echo "[PASS] non-EVM sync leaves the committed config byte-identical (no-drift metadata refresh)"
    else
        fail=$((fail + 1))
        failures+=("non-EVM sync churn")
        echo "[FAIL] non-EVM sync mutated config/chains/solana-devnet.json on a no-drift refresh"
    fi
fi

# 13. sync-check against the fixture server -> CLEAN exit 0 (offline check path). The throwaway is a
#     copy of the committed sepolia file (name stays the canonical selectorName so the guard passes),
#     so every synced field (ccip{} + metadata) already matches the fixture.
cp config/chains/ethereum-testnet-sepolia.json "$TMP_FILE"
run_case "fixture sync-check: clean against the fixture server" zero "CLEAN" -- \
    env CCIP_API_BASE="http://127.0.0.1:$port" bash script/config/sync-check.sh "$TMP_CHAIN"
rm -f "$TMP_FILE"

# 13b. group isolation of sync: `make sync` refreshes only config/chains/<chain>.json (chain facts) and
#      NEVER touches any group's project file. Plant a project/<group>/<chain>.json, run the fixture
#      sync, and assert the group file is byte-identical (the project-untouched shasum gate, extended to
#      project/*/*.json).
cp config/chains/ethereum-testnet-sepolia.json "$TMP_FILE"
mkdir -p "project/$GRP_X"
printf '{"addresses":{"active":{"token":"0x1111111111111111111111111111111111111111"},"deployments":{}},"lanes":{},"roles":{},"schema":3}' > "project/$GRP_X/$TMP_CHAIN.json"
grp_before="$(shasum "project/$GRP_X/$TMP_CHAIN.json")"
CCIP_API_BASE="http://127.0.0.1:$port" FOUNDRY_PROFILE=sync \
    forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" "$TMP_CHAIN" > /dev/null 2>&1
grp_after="$(shasum "project/$GRP_X/$TMP_CHAIN.json")"
if [ "$grp_before" = "$grp_after" ]; then
    pass=$((pass + 1))
    echo "[PASS] sync leaves project/$GRP_X/$TMP_CHAIN.json byte-identical (sync never touches a group's project file)"
else
    fail=$((fail + 1))
    failures+=("sync group-file isolation")
    echo "[FAIL] sync mutated the group project file project/$GRP_X/$TMP_CHAIN.json"
fi
rm -f "$TMP_FILE"
rm -rf "project/$GRP_X"

# 13c. caller env beats .env: sync-check sources ./.env to fill GAPS only - a var the caller already
#      set must survive the sourcing. Plant CCIP_API_BASE=<unreachable> in .env (backup/restore, also
#      covered by cleanup()), inject the fixture-server base from the caller: CLEAN exit 0 proves the
#      caller's value won (a source-overrides regression would hit the unreachable base and exit 2).
if offline_enabled; then
    if [ -f ./.env ]; then
        env_bak="$(mktemp)"
        cp ./.env "$env_bak"
    fi
    env_planted=1
    printf '\nCCIP_API_BASE=http://127.0.0.1:1\n' >> ./.env
    cp config/chains/ethereum-testnet-sepolia.json "$TMP_FILE"
    run_case "sync-check: caller CCIP_API_BASE beats the .env value" zero "CLEAN" -- \
        env CCIP_API_BASE="http://127.0.0.1:$port" bash script/config/sync-check.sh "$TMP_CHAIN"
    rm -f "$TMP_FILE"
    restore_env
fi

# ---------------------------------------------------------------- check-chain doctor

# 14. unknown chain -> attributed FAIL + nonzero verdict
run_case "check-chain unknown chain FAILs with the add-chain hint" nonzero "config: no config/chains/doesnotexist" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" doesnotexist

# 15. non-EVM chain -> schema parse only, 0 FAIL
run_case_live "check-chain on solana-devnet passes (non-EVM path)" zero "0 FAIL" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" solana-devnet

# 16. EVM chain with rpcEnv unset -> rpc SKIP (not FAIL), overall 0 FAIL (live API for the drift rung).
#     Injected present-but-empty, NOT `env -u`: forge auto-loads the repo-root .env and re-sets a var
#     that is absent from the environment, while dotenv never overrides a var that is present, even
#     empty. `_checkRpc` treats empty as unset (`vm.envOr` + zero-length -> SKIP), so an empty
#     injection proves the SKIP path on any machine, whatever the local .env defines.
run_case_live "check-chain SKIPs rpc when the rpcEnv var is unset" zero "\[SKIP\] rpc: env MANTLE_SEPOLIA_RPC_URL unset" -- \
    env MANTLE_SEPOLIA_RPC_URL= FOUNDRY_PROFILE=sync \
    forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" ethereum-testnet-sepolia-mantle-1


# ---------------------------------------------------------------- Makefile golden path

# 17. the make wrappers guard their arguments and stay consistent with the scripts they wrap.
run_case "make help lists the golden-path targets" zero "add-chain" -- \
    make help
run_case "make tools reports the required tools" zero "all present" -- \
    make tools
run_case "make add-chain without CHAIN errors up front" nonzero "CHAIN is required" -- \
    make add-chain
run_case "make add-chain without SELECTOR errors up front" nonzero "SELECTOR is required" -- \
    make add-chain CHAIN=tooling-make-tmp
run_case "make sync on an unknown chain prints the add-chain hint" nonzero "make add-chain CHAIN=" -- \
    make sync CHAIN=doesnotexist
run_case "make doctor without CHAIN errors up front" nonzero "CHAIN is required" -- \
    make doctor

# 18. the make exit-code remap: the canonical 0/1/2 contract belongs to sync-check.sh (case 10
#     proved drift -> exit 1 there); GNU make remaps ANY failing recipe to ITS OWN exit 2, so
#     `make sync-check` reports the same drift as exit 2 - pass/fail only. CI must call the script.
if live_enabled; then
    python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['ccip']['router'] = '0x0000000000000000000000000000000000000001'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
    out="$(make sync-check CHAIN="$TMP_CHAIN" 2>&1)"
    status=$?
    if [ $status -eq 2 ] && grep -q "CONFIG_DRIFT" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] make sync-check remaps the script's drift exit 1 to make exit 2 (pass/fail only)"
    else
        fail=$((fail + 1))
        failures+=("make sync-check remap")
        echo "[FAIL] make sync-check remap (exit=$status, expected 2 + /CONFIG_DRIFT/)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    rm -f "$TMP_FILE"
fi

# ---------------------------------------------------------------- add-lane + mesh doctor

# 21. make add-lane preflights: every missing argument errors up front with the usage line.
run_case "make add-lane without LOCAL errors up front" nonzero "LOCAL is required" -- \
    make add-lane
run_case "make add-lane without REMOTE errors up front" nonzero "REMOTE is required" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia
run_case "make add-lane without CAPACITY errors up front" nonzero "CAPACITY is required" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=ethereum-testnet-sepolia-mantle-1
run_case "make add-lane without RATE errors up front" nonzero "RATE is required" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=ethereum-testnet-sepolia-mantle-1 CAPACITY=1

# 22. unknown remote -> friendly list of known chains + the add-chain hint
run_case "make add-lane with an unknown remote lists known chains" nonzero "unknown chain 'nope'" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=nope CAPACITY=1 RATE=1

# 23. self-lane, same name -> refused (no write happens; the guard fires before any file write)
run_case "add-lane same-name self-lane is refused" nonzero "must be different chains" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=ethereum-testnet-sepolia CAPACITY=1 RATE=1

# 24. self-lane, two FILES sharing one chainSelector (same chain under two names) -> refused. The
#     throwaway is a copy of sepolia with only the name changed, so the selectors collide.
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['name'] = '$TMP_CHAIN'
json.dump(d, open('$TMP_FILE','w'), indent=2, sort_keys=True)
"
run_case "add-lane same-selector remote is refused (self-lane)" nonzero "share chainSelector" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE="$TMP_CHAIN" CAPACITY=1 RATE=1
rm -f "$TMP_FILE"

# 25. add-lane on a scratch pair (no addresses/<chainId>.json for either): the lane is written with
#     the remote's selector, and the remote's still-undeployed pool is a WARN naming the missing
#     deploy - a declared-ahead-of-deploy lane, not a silent success.
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
for name, cid, sel in [('$TMP_CHAIN','990001','9900010000000000001'),
                       ('$TMP_CHAIN_B','990002','9900020000000000002')]:
    d2 = dict(d)
    d2['name'] = name; d2['chainId'] = cid; d2['chainSelector'] = sel
    d2['chainNameIdentifier'] = name.upper().replace('-','_')
    d2['rpcEnv'] = d2['chainNameIdentifier'] + '_RPC_URL'
    json.dump(d2, open('config/chains/%s.json' % name,'w'), indent=2, sort_keys=True)
"
rm -f "$PROJECT_FILE" "$PROJECT_FILE_B"
out="$(make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 2>&1)"
status=$?
if [ $status -eq 0 ] &&
    grep -q "wrote lane $TMP_CHAIN -> $TMP_CHAIN_B remoteSelector=9900020000000000002" <<< "$out" &&
    grep -q "WARN: no tokenPool in project/$TMP_CHAIN_B.json" <<< "$out"; then
    pass=$((pass + 1))
    echo "[PASS] add-lane writes the lane + WARNs on the remote's placeholder pool (names the missing deploy)"
else
    fail=$((fail + 1))
    failures+=("add-lane placeholder WARN")
    echo "[FAIL] add-lane placeholder WARN (exit=$status)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi

# 26. identical re-run (SAME capacity/rate the lane was written with) -> logged no-op, byte-identical.
#     Assert block shares its action's partition (a skipped action would make before==after vacuous).
if offline_enabled; then
    before="$(shasum "$PROJECT_FILE")"
    run_case "add-lane identical re-run is a logged no-op" zero "already exists - no-op" -- \
        make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10
    after="$(shasum "$PROJECT_FILE")"
    if [ "$before" = "$after" ]; then
        pass=$((pass + 1))
        echo "[PASS] add-lane identical re-run left project/${TMP_CHAIN}.json byte-identical"
    else
        fail=$((fail + 1))
        failures+=("add-lane identical re-run byte-identical")
        echo "[FAIL] add-lane identical re-run MUTATED ${TMP_CHAIN}.json"
    fi
fi

# 26b. changed args (DIFFERENT capacity/rate) on an existing entry -> WARN naming existing vs
#      requested, entry left UNCHANGED (never a silent policy rewrite, never a silent no-op).
#      Assert block shares its action's partition.
if offline_enabled; then
    before="$(shasum "$PROJECT_FILE")"
    run_case "add-lane changed args WARNs and leaves the entry unchanged" zero \
        "already exists with DIFFERENT policy (existing capacity=1000 rate=10, requested capacity=5 rate=5)" -- \
        make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=5 RATE=5
    after="$(shasum "$PROJECT_FILE")"
    if [ "$before" = "$after" ]; then
        pass=$((pass + 1))
        echo "[PASS] add-lane changed-args left project/${TMP_CHAIN}.json byte-identical"
    else
        fail=$((fail + 1))
        failures+=("add-lane changed-args byte-identical")
        echo "[FAIL] add-lane changed-args MUTATED ${TMP_CHAIN}.json"
    fi
fi

# 27. one-sided lane -> the doctor's mesh-reciprocity rung FAILs naming BOTH chains (the API rung
#     WARNs on the unknown scratch selector - flake handling, not failure - so the mesh FAIL is
#     what makes the verdict nonzero)
run_case "doctor FAILs a one-sided lane naming both chains" nonzero \
    "one-sided lane $TMP_CHAIN -> $TMP_CHAIN_B ($TMP_CHAIN_B has no lanes.$TMP_CHAIN entry)" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN"

# 28. the reciprocal entry clears it: doctor back to 0 FAIL
make add-lane LOCAL="$TMP_CHAIN_B" REMOTE="$TMP_CHAIN" CAPACITY=1000 RATE=10 > /dev/null 2>&1
run_case "doctor passes once the lane is reciprocated" zero "0 FAIL" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN"

# 28b. the LANES rung (on-chain lane reconciliation) is RPC-gated: with TOOLING_TMP_RPC_URL unset it
#      SKIPs cleanly instead of blocking an offline doctor run. The reconciliation logic itself needs
#      a fork and is covered by test/config/VerifyChainLaneReconcile.t.sol.
run_case "doctor lanes rung SKIPs cleanly without an RPC" zero \
    "lanes: on-chain reconciliation needs an RPC" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN"

# 29. BOTH=1 writes the reciprocal entry on the remote's file in the same invocation
rm -f "$TMP_FILE" "$TMP_FILE_B"
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
for name, cid, sel in [('$TMP_CHAIN','990001','9900010000000000001'),
                       ('$TMP_CHAIN_B','990002','9900020000000000002')]:
    d2 = dict(d)
    d2['name'] = name; d2['chainId'] = cid; d2['chainSelector'] = sel
    d2['chainNameIdentifier'] = name.upper().replace('-','_')
    d2['rpcEnv'] = d2['chainNameIdentifier'] + '_RPC_URL'
    json.dump(d2, open('config/chains/%s.json' % name,'w'), indent=2, sort_keys=True)
"
rm -f "$PROJECT_FILE" "$PROJECT_FILE_B"
out="$(make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 BOTH=1 2>&1)"
status=$?
if [ $status -eq 0 ] &&
    grep -q "wrote lane $TMP_CHAIN -> $TMP_CHAIN_B" <<< "$out" &&
    grep -q "wrote lane $TMP_CHAIN_B -> $TMP_CHAIN" <<< "$out"; then
    pass=$((pass + 1))
    echo "[PASS] add-lane BOTH=1 writes the lane AND its reciprocal"
else
    fail=$((fail + 1))
    failures+=("add-lane BOTH=1")
    echo "[FAIL] add-lane BOTH=1 (exit=$status)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE" "$TMP_FILE_B"

# 29b. add-lane INBOUND_* pairing guard: one arg without the other errors up front (a declared
#      inbound block carries both fields).
run_case "make add-lane with INBOUND_CAPACITY but no INBOUND_RATE errors up front" nonzero \
    "INBOUND_RATE is required" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=ethereum-testnet-sepolia-mantle-1 CAPACITY=1 RATE=1 INBOUND_CAPACITY=5
run_case "make add-lane with INBOUND_RATE but no INBOUND_CAPACITY errors up front" nonzero \
    "INBOUND_CAPACITY is required" -- \
    make add-lane LOCAL=ethereum-testnet-sepolia REMOTE=ethereum-testnet-sepolia-mantle-1 CAPACITY=1 RATE=1 INBOUND_RATE=5

# 29c. add-lane with BOTH inbound args writes the inbound{} policy block (scratch pair, offline).
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
for name, cid, sel in [('$TMP_CHAIN','990001','9900010000000000001'),
                       ('$TMP_CHAIN_B','990002','9900020000000000002')]:
    d2 = dict(d)
    d2['name'] = name; d2['chainId'] = cid; d2['chainSelector'] = sel
    d2['chainNameIdentifier'] = name.upper().replace('-','_')
    d2['rpcEnv'] = d2['chainNameIdentifier'] + '_RPC_URL'
    json.dump(d2, open('config/chains/%s.json' % name,'w'), indent=2, sort_keys=True)
"
rm -f "$PROJECT_FILE" "$PROJECT_FILE_B"
out="$(make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 INBOUND_CAPACITY=55 INBOUND_RATE=5 2>&1)"
status=$?
if [ $status -eq 0 ] &&
    grep -q "inboundCapacity=55 inboundRate=5" <<< "$out" &&
    [ "$(jq -r ".lanes[\"$TMP_CHAIN_B\"].inbound.capacity" "$PROJECT_FILE")" = "55" ] &&
    [ "$(jq -r ".lanes[\"$TMP_CHAIN_B\"].inbound.rate" "$PROJECT_FILE")" = "5" ]; then
    pass=$((pass + 1))
    echo "[PASS] add-lane INBOUND_* writes the inbound policy block"
else
    fail=$((fail + 1))
    failures+=("add-lane inbound block")
    echo "[FAIL] add-lane inbound block (exit=$status)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE" "$TMP_FILE_B"

# ---------------------------------------------------------------- remove-lane

# 30. make remove-lane preflights: every missing argument errors up front with the usage line.
run_case "make remove-lane without LOCAL errors up front" nonzero "LOCAL is required" -- \
    make remove-lane
run_case "make remove-lane without REMOTE errors up front" nonzero "REMOTE is required" -- \
    make remove-lane LOCAL=ethereum-testnet-sepolia

# 30b. a real removal on the throwaway pair: the target entry is gone and a sibling lane entry
#      (with its inbound{} block) survives intact in the same file.
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
for name, cid, sel in [('$TMP_CHAIN','990001','9900010000000000001'),
                       ('$TMP_CHAIN_B','990002','9900020000000000002')]:
    d2 = dict(d)
    d2['name'] = name; d2['chainId'] = cid; d2['chainSelector'] = sel
    d2['chainNameIdentifier'] = name.upper().replace('-','_')
    d2['rpcEnv'] = d2['chainNameIdentifier'] + '_RPC_URL'
    json.dump(d2, open('config/chains/%s.json' % name,'w'), indent=2, sort_keys=True)
"
rm -f "$PROJECT_FILE" "$PROJECT_FILE_B"
make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 > /dev/null 2>&1
make add-lane LOCAL="$TMP_CHAIN" REMOTE=ethereum-testnet-sepolia CAPACITY=7 RATE=7 INBOUND_CAPACITY=55 INBOUND_RATE=5 > /dev/null 2>&1
out="$(make remove-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" 2>&1)"
status=$?
if [ $status -eq 0 ] &&
    grep -q "removed lane $TMP_CHAIN -> $TMP_CHAIN_B from project/$TMP_CHAIN.json" <<< "$out" &&
    grep -q "the pool is untouched" <<< "$out" &&
    [ "$(jq -r ".lanes | has(\"$TMP_CHAIN_B\")" "$PROJECT_FILE")" = "false" ] &&
    [ "$(jq -r '.lanes["ethereum-testnet-sepolia"].capacity' "$PROJECT_FILE")" = "7" ] &&
    [ "$(jq -r '.lanes["ethereum-testnet-sepolia"].inbound.capacity' "$PROJECT_FILE")" = "55" ]; then
    pass=$((pass + 1))
    echo "[PASS] remove-lane removes the target entry, sibling lane (incl. inbound block) intact"
else
    fail=$((fail + 1))
    failures+=("remove-lane real removal")
    echo "[FAIL] remove-lane real removal (exit=$status)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi

# 30c. removing an undeclared lane is a logged no-op, exit 0, file byte-identical. Assert block
#      shares its action's partition.
if offline_enabled; then
    before="$(shasum "$PROJECT_FILE")"
    run_case "remove-lane on an undeclared lane is a logged no-op" zero "is not declared - no-op" -- \
        make remove-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B"
    after="$(shasum "$PROJECT_FILE")"
    if [ "$before" = "$after" ]; then
        pass=$((pass + 1))
        echo "[PASS] remove-lane no-op left project/${TMP_CHAIN}.json byte-identical"
    else
        fail=$((fail + 1))
        failures+=("remove-lane no-op byte-identical")
        echo "[FAIL] remove-lane no-op MUTATED ${TMP_CHAIN}.json"
    fi
fi

# 30d. BOTH=1 removes the lane AND its reciprocal in the same invocation.
make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 BOTH=1 > /dev/null 2>&1
out="$(make remove-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" BOTH=1 2>&1)"
status=$?
if [ $status -eq 0 ] &&
    grep -q "removed lane $TMP_CHAIN -> $TMP_CHAIN_B" <<< "$out" &&
    grep -q "removed lane $TMP_CHAIN_B -> $TMP_CHAIN" <<< "$out" &&
    [ "$(jq -r ".lanes | has(\"$TMP_CHAIN_B\")" "$PROJECT_FILE")" = "false" ] &&
    [ "$(jq -r ".lanes | has(\"$TMP_CHAIN\")" "$PROJECT_FILE_B")" = "false" ]; then
    pass=$((pass + 1))
    echo "[PASS] remove-lane BOTH=1 removes the lane AND its reciprocal"
else
    fail=$((fail + 1))
    failures+=("remove-lane BOTH=1")
    echo "[FAIL] remove-lane BOTH=1 (exit=$status)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE" "$TMP_FILE_B"

# ---------------------------------------------------------------- canonical config format

# 19. the canonical-format guarantee: committed configs ARE canon (fmt-config -> no diff vs the git
#     index), fmt-config is idempotent (second run byte-identical), and a real live `make sync` on a
#     clean chain yields ZERO git diff (the recipe re-canonicalizes vm.writeJson's output).
run_case "make fmt-config runs clean" zero "canonicalized" -- \
    make fmt-config
# Zero-diff assert shares the fmt-config action's partition (vacuous when the action was skipped).
if offline_enabled; then
    if git diff --exit-code --quiet -- config/chains/; then
        pass=$((pass + 1))
        echo "[PASS] fmt-config: committed configs are already canonical (zero git diff)"
    else
        fail=$((fail + 1))
        failures+=("fmt-config committed==canon")
        echo "[FAIL] fmt-config: committed configs are NOT canonical (git diff below)"
        git diff --stat -- config/chains/ | sed 's/^/       | /'
    fi
fi
before="$(shasum config/chains/*.json)"
make fmt-config > /dev/null 2>&1
after="$(shasum config/chains/*.json)"
if [ "$before" = "$after" ]; then
    pass=$((pass + 1))
    echo "[PASS] fmt-config: second run is idempotent (files byte-identical)"
else
    fail=$((fail + 1))
    failures+=("fmt-config idempotency")
    echo "[FAIL] fmt-config: second run mutated the files"
fi

# 19b. clean-scratch removes planted test-scratch fixtures (project file + config file + group dir +
#      history dir) via explicit patterns - never `git clean -X`, which would also delete the user's
#      REAL gitignored project state. Planted names are in cleanup()'s rm-list.
if offline_enabled; then
    printf '{"schema":3}' > "$CLEANX_PROJECT"
    printf '{"schema":3}' > "$CLEANX_CONFIG"
    mkdir -p "$CLEANX_GRPDIR" "$CLEANX_HISTDIR"
    out="$(make clean-scratch 2>&1)"
    status=$?
    if [ $status -eq 0 ] && grep -q "clean-scratch: removed" <<< "$out" &&
        [ ! -e "$CLEANX_PROJECT" ] && [ ! -e "$CLEANX_CONFIG" ] &&
        [ ! -d "$CLEANX_GRPDIR" ] && [ ! -d "$CLEANX_HISTDIR" ]; then
        pass=$((pass + 1))
        echo "[PASS] make clean-scratch removes planted scratch file + config + group dir + history dir"
    else
        fail=$((fail + 1))
        failures+=("make clean-scratch")
        echo "[FAIL] make clean-scratch (exit=$status; a planted scratch path survived)"
        echo "$out" | tail -4 | sed 's/^/       | /'
    fi
fi

# 20. live zero-diff sync: with sync-check CLEAN (no value drift), `make sync` must be byte-identical
#     to the committed file — this is the no-churn guarantee the canonical format exists for.
if live_enabled; then
    if bash script/config/sync-check.sh ethereum-testnet-sepolia > /dev/null 2>&1; then
        make sync CHAIN=ethereum-testnet-sepolia > /dev/null 2>&1
        if git diff --exit-code --quiet -- config/chains/ethereum-testnet-sepolia.json; then
            pass=$((pass + 1))
            echo "[PASS] live sync on a CLEAN chain yields zero git diff (canonical format)"
        else
            fail=$((fail + 1))
            failures+=("live sync zero-diff")
            echo "[FAIL] live sync on a CLEAN chain produced a git diff:"
            git diff -- config/chains/ethereum-testnet-sepolia.json | head -20 | sed 's/^/       | /'
            git checkout -- config/chains/ethereum-testnet-sepolia.json 2> /dev/null
        fi
    else
        fail=$((fail + 1))
        failures+=("live sync zero-diff (precheck)")
        echo "[FAIL] live sync zero-diff: precheck sync-check ethereum-testnet-sepolia not CLEAN (drift or API down)"
    fi
fi


# 30. adopt-token missing-arg preflights: CHAIN and TOKEN are required, each named in the error.
if out=$(make adopt-token TOKEN=0x0000000000000000000000000000000000000001 2>&1) || ! grep -q "CHAIN is required" <<< "$out"; then
    fail=$((fail + 1))
    failures+=("adopt-token missing CHAIN: accepted or error does not name CHAIN")
    echo "[FAIL] adopt-token without CHAIN: accepted or error does not name CHAIN"
else
    pass=$((pass + 1))
    echo "[PASS] adopt-token without CHAIN is refused naming CHAIN"
fi

# 31. adopt-token without TOKEN is refused, naming TOKEN.
if out=$(make adopt-token CHAIN=ethereum-testnet-sepolia 2>&1) || ! grep -q "TOKEN is required" <<< "$out"; then
    fail=$((fail + 1))
    failures+=("adopt-token missing TOKEN: accepted or error does not name TOKEN")
    echo "[FAIL] adopt-token without TOKEN: accepted or error does not name TOKEN"
else
    pass=$((pass + 1))
    echo "[PASS] adopt-token without TOKEN is refused naming TOKEN"
fi

# 32. adopt-token on an unknown chain is refused, naming the chain and hinting add-chain.
if out=$(make adopt-token CHAIN=zz-no-such-chain TOKEN=0x0000000000000000000000000000000000000001 2>&1) \
    || ! grep -q "unknown chain 'zz-no-such-chain'" <<< "$out" || ! grep -q "make add-chain" <<< "$out"; then
    fail=$((fail + 1))
    failures+=("adopt-token unknown chain: accepted or missing name/add-chain hint")
    echo "[FAIL] adopt-token on an unknown chain: accepted or missing name/add-chain hint"
else
    pass=$((pass + 1))
    echo "[PASS] adopt-token on an unknown chain is refused with the add-chain hint"
fi

# ---------------------------------------------------------------- token groups
#
# The ENV path the in-process forge seam (test/config/TokenGroups.t.sol) cannot drive: a real
# `GROUP=<g> make` subprocess owns its own PROJECT_GROUP, so these cases prove the env-driven group()
# end to end - grouped first-touch seed, cross-group byte isolation, per-group reciprocity, repoint-warn
# extinction, name validation, the base58 adopt path, roles-check group iteration, and doctor scoping.

if offline_enabled; then
    # Two scratch EVM chains (sepolia copies with distinct selectors) reused across the group cases.
    seed_group_pair() {
        rm -f "$TMP_FILE" "$TMP_FILE_B" "$PROJECT_FILE" "$PROJECT_FILE_B"
        rm -rf "project/$GRP_X" "project/$GRP_Y"
        python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
for name, cid, sel in [('$TMP_CHAIN','990001','9900010000000000001'),
                       ('$TMP_CHAIN_B','990002','9900020000000000002')]:
    d2 = dict(d); d2['name'] = name; d2['chainId'] = cid; d2['chainSelector'] = sel
    d2['chainNameIdentifier'] = name.upper().replace('-', '_'); d2['rpcEnv'] = d2['chainNameIdentifier'] + '_RPC_URL'
    json.dump(d2, open('config/chains/%s.json' % name, 'w'), indent=2, sort_keys=True)
"
    }

    # G1. first-touch GROUP= add-lane seeds project/<group>/<local>.json (exit 0, canonical: schema 3,
    #     NO trailing newline) with the flat project/<local>.json UNTOUCHED (absent). Then a GROUP-less
    #     add-lane of the same pair produces a flat file BYTE-IDENTICAL to the grouped one - proving the
    #     group is a pure path segment, the data unchanged (the flat-default byte-equivalence guarantee).
    seed_group_pair
    GROUP_FILE_X="project/$GRP_X/$TMP_CHAIN.json"
    out="$(make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 GROUP="$GRP_X" 2>&1)"
    status=$?
    if [ $status -eq 0 ] &&
        grep -q "wrote lane $TMP_CHAIN -> $TMP_CHAIN_B" <<< "$out" &&
        [ -f "$GROUP_FILE_X" ] && [ ! -f "$PROJECT_FILE" ] &&
        [ "$(jq -r '.schema' "$GROUP_FILE_X")" = "3" ] &&
        [ "$(tail -c1 "$GROUP_FILE_X" | xxd -p)" != "0a" ]; then
        pass=$((pass + 1))
        echo "[PASS] group add-lane first-touch seeds project/$GRP_X/$TMP_CHAIN.json (canonical), flat file untouched"
    else
        fail=$((fail + 1))
        failures+=("group first-touch seed")
        echo "[FAIL] group first-touch seed (exit=$status, grouped=$([ -f "$GROUP_FILE_X" ] && echo yes) flat=$([ -f "$PROJECT_FILE" ] && echo present))"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 > /dev/null 2>&1 # GROUP-less flat
    if cmp -s "$PROJECT_FILE" "$GROUP_FILE_X"; then
        pass=$((pass + 1))
        echo "[PASS] flat-default byte-equivalence: flat project file == grouped file (group is a pure path segment)"
    else
        fail=$((fail + 1))
        failures+=("flat-vs-grouped byte-equivalence")
        echo "[FAIL] flat project file differs from the grouped file (group changed the data, not just the path)"
    fi

    # G2. cross-group byte isolation: with GRP_X populated, an add-lane under GRP_Y writes only the GRP_Y
    #     file; GRP_X's file is byte-identical (shasum unchanged). Separate mesh universes.
    before="$(shasum "$GROUP_FILE_X")"
    make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=5 RATE=5 GROUP="$GRP_Y" > /dev/null 2>&1
    after="$(shasum "$GROUP_FILE_X")"
    if [ "$before" = "$after" ] && [ -f "project/$GRP_Y/$TMP_CHAIN.json" ]; then
        pass=$((pass + 1))
        echo "[PASS] cross-group isolation: writing group $GRP_Y left group $GRP_X byte-identical"
    else
        fail=$((fail + 1))
        failures+=("cross-group isolation")
        echo "[FAIL] cross-group isolation: group $GRP_X changed when group $GRP_Y was written"
    fi

    # G3. per-group reciprocity: a one-sided lane in GRP_X FAILs the doctor (naming both chains); adding
    #     the reciprocal in a DIFFERENT group (GRP_Y) does NOT satisfy it - reciprocity is per-group.
    seed_group_pair
    make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 GROUP="$GRP_X" > /dev/null 2>&1
    make add-lane LOCAL="$TMP_CHAIN_B" REMOTE="$TMP_CHAIN" CAPACITY=1000 RATE=10 GROUP="$GRP_Y" > /dev/null 2>&1 # reciprocal in the WRONG group
    run_case "doctor per-group reciprocity FAILs a lane reciprocated only in another group" nonzero \
        "one-sided lane $TMP_CHAIN -> $TMP_CHAIN_B" -- \
        env FOUNDRY_PROFILE=sync PROJECT_GROUP="$GRP_X" \
        forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN"

    # G4. verdict equivalence: the SAME store content flat vs in a group yields identical FAIL/WARN
    #     tallies (the group changes only the file location, never the doctor's verdict).
    seed_group_pair
    make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 BOTH=1 > /dev/null 2>&1            # flat, reciprocated
    make add-lane LOCAL="$TMP_CHAIN" REMOTE="$TMP_CHAIN_B" CAPACITY=1000 RATE=10 BOTH=1 GROUP="$GRP_X" > /dev/null 2>&1 # same, grouped
    flat_verdict="$(FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN" 2>&1 | grep -oE "[0-9]+ FAIL, [0-9]+ WARN" | tail -1)"
    grp_out="$(FOUNDRY_PROFILE=sync PROJECT_GROUP="$GRP_X" forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN" 2>&1)"
    grp_verdict="$(echo "$grp_out" | grep -oE "[0-9]+ FAIL, [0-9]+ WARN" | tail -1)"
    # Non-vacuous: the grouped run must have read the GROUPED file (not silently the flat one), so the
    # tally match is between two runs that genuinely resolved different paths.
    if [ -n "$flat_verdict" ] && [ "$flat_verdict" = "$grp_verdict" ] && grep -q "project/$GRP_X/$TMP_CHAIN.json" <<< "$grp_out"; then
        pass=$((pass + 1))
        echo "[PASS] doctor verdict equivalence flat vs grouped ($flat_verdict) - same tree, same tallies, grouped read its own file"
    else
        fail=$((fail + 1))
        failures+=("doctor verdict equivalence")
        echo "[FAIL] doctor verdict flat='$flat_verdict' != grouped='$grp_verdict'"
    fi

    # G5. doctor group-scoping: each run reads ONLY its own group's project file. A CORRUPT
    #     (wrong-schema) sibling file in GRP_Y does NOT poison the GRP_X run (still 0 FAIL - the project
    #     store is an OPTIONAL, tolerant read), and the GRP_X run names its OWN group path, never the
    #     sibling's. The GRP_Y run in turn names GRP_Y's path - the scoping is real, not accidental.
    mkdir -p "project/$GRP_Y"
    printf '{"addresses":{"active":{},"deployments":{}},"lanes":{},"roles":{},"schema":999}' > "project/$GRP_Y/$TMP_CHAIN.json"
    out="$(FOUNDRY_PROFILE=sync PROJECT_GROUP="$GRP_X" forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN" 2>&1)"
    status=$?
    if [ $status -eq 0 ] && grep -q "0 FAIL" <<< "$out" &&
        grep -q "project/$GRP_X/$TMP_CHAIN.json" <<< "$out" &&
        ! grep -q "project/$GRP_Y/" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] doctor GROUP=$GRP_X scoped to its own file, unpoisoned by the corrupt sibling group"
    else
        fail=$((fail + 1))
        failures+=("doctor group scoping (GRP_X)")
        echo "[FAIL] doctor GROUP=$GRP_X scoping (exit=$status; read the sibling group or FAILed)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    run_case "doctor GROUP=$GRP_Y reads its OWN group file (scoping is real)" zero \
        "project/$GRP_Y/$TMP_CHAIN.json" -- \
        env FOUNDRY_PROFILE=sync PROJECT_GROUP="$GRP_Y" \
        forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN"

    # G5b. the UNGROUPED doctor NOTICES a chain that also lives in a (visible, non-scratch) token group,
    #      so a routine no-GROUP check does not silently skip it; the grouped run itself prints no notice.
    #      A zz-scratch-* group would be skipped (leaked-scratch class), so a zz-tt-* group is used.
    mkdir -p project/zz-tt-ga
    printf '{"addresses":{"active":{},"deployments":{}},"lanes":{},"roles":{},"schema":3}' > "project/zz-tt-ga/$TMP_CHAIN.json"
    ungrouped="$(FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN" 2>&1)"
    grouped="$(FOUNDRY_PROFILE=sync PROJECT_GROUP=zz-tt-ga forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" "$TMP_CHAIN" 2>&1)"
    if grep -q "also has token group(s): zz-tt-ga" <<< "$ungrouped" &&
        ! grep -q "also has token group(s)" <<< "$grouped"; then
        pass=$((pass + 1))
        echo "[PASS] ungrouped doctor notices the grouped sibling; the grouped run does not"
    else
        fail=$((fail + 1))
        failures+=("doctor grouped-sibling notice")
        echo "[FAIL] doctor grouped-sibling notice (ungrouped missing it, or grouped printed it)"
        echo "$ungrouped" | grep -i "token group" | sed 's/^/       | /'
    fi
    rm -rf project/zz-tt-ga

    # G6. invalid PROJECT_GROUP on a READ path is a NAMED error, nonzero - never a silent seed. (The
    #     GROUP= make var routes to PROJECT_GROUP; a name with a space breaks make word-splitting before
    #     validation, so the invalid names here are single shell words that reach the validator.)
    for badg in "Bad" "a_b" "-x" "a/b" ".." "."; do
        run_case "make doctor GROUP=$badg is refused with the named group-validation error" nonzero \
            "is not a valid token-group name" -- \
            make doctor CHAIN="$TMP_CHAIN" GROUP="$badg"
    done

    # G7. non-EVM base58 adopt per group + repoint-warn EXTINCTION. A scratch SVM chain: adopt token1
    #     flat, then adopt a DIFFERENT token under GROUP=$GRP_Y - the grouped adopt writes
    #     project/$GRP_Y/<svm>.json with the base58 value, fires NO repoint warning, and leaves the flat
    #     file byte-identical. A second flat adopt (same store) DOES fire the repoint warning naming the
    #     token-group remedy - the exact contrast the group feature exists for.
    rm -f "$SVM_FILE" "project/$SVM_CHAIN.json"
    rm -rf "project/$GRP_Y"
    python3 -c "
import json
d = json.load(open('config/chains/solana-devnet.json'))
d['name'] = '$SVM_CHAIN'; d['chainNameIdentifier'] = 'ZZ_SCRATCH_SVM_GRP'
d['rpcEnv'] = 'ZZ_SCRATCH_SVM_GRP_RPC_URL'; d['chainSelector'] = '9932100000000000009'
json.dump(d, open('$SVM_FILE', 'w'), indent=2, sort_keys=True)
"
    T1_B58="BPympxtoS3GZmNcGiTxqsH6kyRgKiS9QFjfviSLaqxRE"
    T2_B58="ALh3xpZtujrfYZSiURBEHpeBFnzZEH37nY4BA4EHiiB5"
    make adopt-token CHAIN="$SVM_CHAIN" TOKEN_B58="$T1_B58" > /dev/null 2>&1 # flat token1
    flat_before="$(shasum "project/$SVM_CHAIN.json")"
    out="$(make adopt-token CHAIN="$SVM_CHAIN" TOKEN_B58="$T2_B58" GROUP="$GRP_Y" 2>&1)"
    flat_after="$(shasum "project/$SVM_CHAIN.json")"
    grp_token="$(jq -r '.addresses.active.token' "project/$GRP_Y/$SVM_CHAIN.json" 2> /dev/null)"
    if ! grep -qi "repointed" <<< "$out" &&
        [ "$flat_before" = "$flat_after" ] &&
        [ "$grp_token" = "$T2_B58" ]; then
        pass=$((pass + 1))
        echo "[PASS] base58 adopt under GROUP=$GRP_Y: no repoint warn, base58 stored in the group, flat file untouched"
    else
        fail=$((fail + 1))
        failures+=("group base58 adopt / repoint extinction")
        echo "[FAIL] group base58 adopt (repoint-warn fired, flat mutated, or base58 not stored: grp_token=$grp_token)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    run_case "flat second adopt fires the repoint warning naming the token-group remedy" zero \
        "belongs in its own group" -- \
        make adopt-token CHAIN="$SVM_CHAIN" TOKEN_B58="$T2_B58"

    # G8. roles-check iterates every token group, labelling each result line [group: <g>]; with no chain
    #     declaring roles{} in any group it stays CLEAN. Two empty group dirs (zz-tt-ga, zz-tt-gb) are scanned
    #     alongside the default group - the group-iteration structure, offline (no chain reconciled).
    rm -rf project/zz-tt-ga project/zz-tt-gb
    mkdir -p project/zz-tt-ga project/zz-tt-gb
    out="$(make roles-check-all 2>&1)"
    status=$?
    if [ $status -eq 0 ] &&
        grep -q "\[group: default\]" <<< "$out" &&
        grep -q "\[group: zz-tt-ga\]" <<< "$out" &&
        grep -q "\[group: zz-tt-gb\]" <<< "$out" &&
        grep -q "roles-check: CLEAN" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] roles-check iterates groups (default + zz-tt-ga + zz-tt-gb) with per-line [group: <g>] labels"
    else
        fail=$((fail + 1))
        failures+=("roles-check group iteration")
        echo "[FAIL] roles-check group iteration (exit=$status, missing a [group: <g>] label or CLEAN)"
        echo "$out" | tail -8 | sed 's/^/       | /'
    fi
    # G8b. zero-groups: with no group dirs, only the default group is scanned (no [group: zz-tt-ga] label).
    rm -rf project/zz-tt-ga project/zz-tt-gb
    out="$(make roles-check-all 2>&1)"
    if grep -q "\[group: default\]" <<< "$out" && ! grep -q "\[group: zz-tt-ga\]" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] roles-check zero-groups: only the default group is scanned (no group dirs present)"
    else
        fail=$((fail + 1))
        failures+=("roles-check zero-groups")
        echo "[FAIL] roles-check zero-groups: an unexpected group was scanned"
    fi
    # G8c. explicit GROUP scopes to ONLY that group (never the default or a sibling).
    rm -rf project/zz-tt-ga project/zz-tt-gb
    mkdir -p project/zz-tt-ga project/zz-tt-gb
    out="$(make roles-check GROUP=zz-tt-ga 2>&1)"
    if grep -q "\[group: zz-tt-ga\]" <<< "$out" &&
        ! grep -q "\[group: default\]" <<< "$out" &&
        ! grep -q "\[group: zz-tt-gb\]" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] roles-check GROUP=zz-tt-ga scopes to that group only (no default/sibling scan)"
    else
        fail=$((fail + 1))
        failures+=("roles-check explicit-group scoping")
        echo "[FAIL] roles-check GROUP=zz-tt-ga scoping (scanned default or a sibling)"
        echo "$out" | tail -8 | sed 's/^/       | /'
    fi
    # G8d. an unknown explicit group fails LOUDLY (never a false CLEAN exit 0 on a typo).
    out="$(make roles-check GROUP=zz-tt-nope 2>&1)"
    status=$?
    if [ $status -ne 0 ] && grep -q "unknown token group" <<< "$out"; then
        pass=$((pass + 1))
        echo "[PASS] roles-check GROUP=<unknown> fails loudly (no false CLEAN)"
    else
        fail=$((fail + 1))
        failures+=("roles-check unknown-group guard")
        echo "[FAIL] roles-check unknown group did not fail loudly (exit=$status)"
        echo "$out" | tail -6 | sed 's/^/       | /'
    fi
    rm -rf project/zz-tt-ga project/zz-tt-gb

    rm -f "$TMP_FILE" "$TMP_FILE_B" "$SVM_FILE" "project/$SVM_CHAIN.json"
    rm -rf "project/$GRP_X" "project/$GRP_Y" project/zz-tt-ga project/zz-tt-gb
fi

# ---------------------------------------------------------------- committed-tree gates (offline)
#
# The project store and the deploy ledger hold local, throwaway, sometimes secret-bearing state, so only
# ONE curated example may ever be committed. These gates PROVE that from the actual git state (never by
# reading .gitignore), and lint any committed project file for secret-shaped values.

if offline_enabled; then
    # H1. `git ls-files project/ history/` lists NO tracked file other than the committed example. Proved
    #     from git itself: any scratch/local/real project file or any history file showing up here is a
    #     hygiene breach. (Empty is fine — the example may be unstaged in a working tree.)
    stray_tracked="$(git ls-files project/ history/ | grep -v '^project/ethereum-testnet-sepolia\.example\.json$' || true)"
    if [ -z "$stray_tracked" ]; then
        pass=$((pass + 1))
        echo "[PASS] git ls-files project/ history/ tracks nothing but the committed example"
    else
        fail=$((fail + 1))
        failures+=("committed-tree: stray tracked project/history file")
        echo "[FAIL] committed-tree: these must NOT be tracked:"
        echo "$stray_tracked" | sed 's/^/       | /'
    fi

    # H2. The ignore contract via `git check-ignore` (executes git's own ignore logic): scratch, local,
    #     and real per-chain project files + the whole history/ ledger are ignored; ONLY the example is
    #     trackable. `check-ignore -q` exits 0 when the path IS ignored.
    ci_ok=1
    for p in \
        project/local-31337.json \
        project/zz-scratch-tooling.json \
        project/ethereum-testnet-sepolia.json \
        "$PROJECT_FILE" \
        history/tokens/ethereum-testnet-sepolia/1-BnM-T-Token.json \
        config/chains/zz-scratch-tooling.json; do
        git check-ignore -q "$p" || {
            ci_ok=0
            echo "       | NOT ignored but should be: $p"
        }
    done
    if git check-ignore -q project/ethereum-testnet-sepolia.example.json; then
        ci_ok=0
        echo "       | the committed example must NOT be ignored (it is the one trackable project file)"
    fi
    if [ $ci_ok -eq 1 ]; then
        pass=$((pass + 1))
        echo "[PASS] gitignore contract: scratch/local/real project + history ignored, example trackable"
    else
        fail=$((fail + 1))
        failures+=("committed-tree: gitignore contract")
        echo "[FAIL] committed-tree: gitignore contract (see above)"
    fi

    # H3. Secret-shaped-value lint: a committed project file must carry only on-chain addresses and
    #     selectorNames — never a URL (RPC/endpoint) or a 0x+64-hex private-key-shaped value. A 32-byte
    #     base58 pubkey (43-44 high-entropy chars) is a legitimate non-EVM address and must NOT trip it.
    secret_lint() { grep -EHn 'https?://|0x[0-9a-fA-F]{64}' "$@"; } # exit 0 == a secret-shaped value found
    sl_fire_url="project/zz-scratch-secretlint-url.json"
    sl_fire_key="project/zz-scratch-secretlint-key.json"
    sl_clean_b58="project/zz-scratch-secretlint-b58.json"
    printf '{"rpc":"https://mainnet.example/v3/DEADBEEFKEY","schema":3}' > "$sl_fire_url"
    printf '{"k":"0x%064d","schema":3}' 1 > "$sl_fire_key"
    printf '{"addresses":{"active":{"tokenPool":"ALh3xpZtujrfYZSiURBEHpeBFnzZEH37nY4BA4EHiiB5"}},"schema":3}' > "$sl_clean_b58"
    sl_ok=1
    secret_lint "$sl_fire_url" > /dev/null || { sl_ok=0; echo "       | FIRE test failed: a URL value was NOT flagged"; }
    secret_lint "$sl_fire_key" > /dev/null || { sl_ok=0; echo "       | FIRE test failed: a 0x+64hex key was NOT flagged"; }
    if secret_lint "$sl_clean_b58" > /dev/null; then
        sl_ok=0
        echo "       | FALSE-POSITIVE: a 32-byte base58 pubkey was flagged as a secret"
    fi
    if secret_lint project/ethereum-testnet-sepolia.example.json > /dev/null; then
        sl_ok=0
        echo "       | the committed example itself tripped the secret lint"
    fi
    rm -f "$sl_fire_url" "$sl_fire_key" "$sl_clean_b58"
    if [ $sl_ok -eq 1 ]; then
        pass=$((pass + 1))
        echo "[PASS] secret-lint: fires on URL + 0x64hex, clean on a base58 pubkey and the example"
    else
        fail=$((fail + 1))
        failures+=("committed-tree: secret-lint")
        echo "[FAIL] committed-tree: secret-lint (see above)"
    fi

    # E1. Stale-string sweep: no relocated-store PATH reference survives anywhere in src+script — a
    #     `script/deployments/<file>` read/write or an `addresses/<chainId>` path (the ledger + address
    #     stores were relocated to history/ and project/). Clean break: no code acknowledges the old
    #     layout at all, so any match is a real relocated-file reader and a FAIL.
    stale_hits="$(grep -rnE 'script/deployments/[^ "`]|addresses/[0-9]' --include='*.sol' src script 2>/dev/null || true)"
    if [ -z "$stale_hits" ]; then
        pass=$((pass + 1))
        echo "[PASS] stale-string sweep: no script/deployments/<file> or addresses/<chainId> path in src+script"
    else
        fail=$((fail + 1))
        failures+=("stale-string sweep")
        echo "[FAIL] stale-string sweep: relocated paths still referenced:"
        echo "$stale_hits" | sed 's/^/       | /'
    fi

    # E1b. Project-path composition gate: a project-file path fragment (`"...project/"` followed by a
    #      chain-name var) must be built ONLY by ProjectStore. Group support makes the path optionally
    #      `project/<group>/<name>.json`, so every path/display string goes through ProjectStore.path()/
    #      display(); a raw `"project/" + name` would be blind to the group. ProjectStore is the one
    #      sanctioned composer.
    inline_hits="$(grep -rnE 'project/"' --include='*.sol' src script 2>/dev/null | grep -v 'src/utils/ProjectStore.sol' || true)"
    if [ -z "$inline_hits" ]; then
        pass=$((pass + 1))
        echo "[PASS] project-path gate: no inline project/<name> composition outside ProjectStore"
    else
        fail=$((fail + 1))
        failures+=("project-path composition gate")
        echo "[FAIL] project-path gate: compose via ProjectStore.path()/display() instead of inline:"
        echo "$inline_hits" | sed 's/^/       | /'
    fi

    # E1c. Group-seam gate: no test may `vm.setEnv("PROJECT_GROUP")`. It is process-global and forge runs
    #      suites in parallel, so a group must be driven through the `*In(group, ...)` seam (in-process) or
    #      a real subprocess env (shell/live tier), never vm.setEnv - the parallel-safety invariant.
    setenv_hits="$(grep -rn 'setEnv("PROJECT_GROUP"' --include='*.sol' test 2>/dev/null || true)"
    if [ -z "$setenv_hits" ]; then
        pass=$((pass + 1))
        echo "[PASS] group-seam gate: no vm.setEnv(PROJECT_GROUP) in test/ (parallel-safe)"
    else
        fail=$((fail + 1))
        failures+=("group-seam vm.setEnv gate")
        echo "[FAIL] group-seam gate: a test sets PROJECT_GROUP via vm.setEnv (use the *In seam or a subprocess env):"
        echo "$setenv_hits" | sed 's/^/       | /'
    fi

    # Config purity: a committed config/chains/*.json is pure API + chain facts — no `lanes`,
    # `roles`, `ccipBnM`, or `ccvThreshold` key (project state lives in the project store; the
    # pool-scoped CCV threshold is declared at poolPolicy.ccvThreshold there).
    impure=""
    for f in config/chains/*.json; do
        case "$f" in *zz-scratch* | "$TMP_FILE" | "$TMP_FILE_B" | "$FUJI_FILE") continue ;; esac
        [ -e "$f" ] || continue
        jq -e 'has("lanes") or has("roles") or has("ccipBnM") or has("ccvThreshold")' "$f" > /dev/null 2>&1 && impure="$impure $f"
    done
    if [ -z "$impure" ]; then
        pass=$((pass + 1))
        echo "[PASS] config purity: no lanes/roles/ccipBnM/ccvThreshold key in any committed config/chains/*.json"
    else
        fail=$((fail + 1))
        failures+=("config purity")
        echo "[FAIL] config purity: these configs still carry a project-state key:$impure"
    fi
fi

echo ""
echo "== test-tooling ($PARTITION): $pass passed, $fail failed =="
if [ $fail -ne 0 ]; then
    printf 'failed: %s\n' "${failures[@]}"
    exit 1
fi
