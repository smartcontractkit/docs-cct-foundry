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
set -uo pipefail

cd "$(dirname "$0")/../.."

TMP_CHAIN="tooling-tmp"
TMP_FILE="config/chains/${TMP_CHAIN}.json"
FIXTURE="test/fixtures/ccip-api/chain-16015286601757825753.json"
SEPOLIA_SELECTOR="16015286601757825753"
# A real, non-bundled chain used by the add-chain print-names case; its generated config is a
# throwaway removed on exit (never committed).
FUJI_CHAIN="avalanche-testnet-fuji"
FUJI_FILE="config/chains/${FUJI_CHAIN}.json"
FUJI_SELECTOR="14767482510784806043"
pass=0
fail=0
declare -a failures=()
server_pid=""
server_dir=""

cleanup() {
    rm -f "$TMP_FILE" "$FUJI_FILE"
    [ -n "$server_pid" ] && kill "$server_pid" 2> /dev/null
    [ -n "$server_dir" ] && rm -rf "$server_dir"
}
trap cleanup EXIT

# run_case <name> <expected: zero|nonzero> <grep-pattern> -- <cmd...>
run_case() {
    local name="$1" expect="$2" pattern="$3"
    shift 4 # name expect pattern --
    local out status
    out="$("$@" 2>&1)"
    status=$?
    local ok=1
    if [ "$expect" = "zero" ] && [ $status -ne 0 ]; then ok=0; fi
    if [ "$expect" = "nonzero" ] && [ $status -eq 0 ]; then ok=0; fi
    if ! echo "$out" | grep -q -- "$pattern"; then ok=0; fi
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

sync_script() {
    FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol "$@"
}

echo "== test-tooling: chain-config tooling failure-path + fixture suite =="

# ---------------------------------------------------------------- guards (no network)

# 1. unknown chain -> helpful list of configured chains, never a raw cheatcode revert
run_case "sync unknown chain lists known chains" nonzero "Known chains:" -- \
    sync_script --sig "run(string)" doesnotexist

# 2. direct invocation without the sync profile -> profile guard with the real fix
run_case "profile guard names the sync profile" nonzero "FOUNDRY_PROFILE=sync" -- \
    forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" ethereum-testnet-sepolia

# 3. add-chain refuses to overwrite an existing config
run_case "add-chain refuses to overwrite an existing config" nonzero "already exists - refusing to overwrite" -- \
    sync_script --sig "init(string,uint256)" ethereum-testnet-sepolia "$SEPOLIA_SELECTOR"

# 4. chain names become file paths + shell args: unsafe names are refused up front
run_case "add-chain rejects a path-traversal name" nonzero "invalid chain name" -- \
    sync_script --sig "init(string,uint256)" "../evil" "$SEPOLIA_SELECTOR"
run_case "add-chain rejects a name with a space" nonzero "invalid chain name" -- \
    sync_script --sig "init(string,uint256)" "evil name" "$SEPOLIA_SELECTOR"

# 5. non-EVM chain -> Solidity-side SKIP (covers every entrypoint), exit 0
run_case "sync on a non-EVM chain SKIPs cleanly" zero "SKIP solana-devnet - chainFamily svm" -- \
    sync_script --sig "run(string)" solana-devnet
run_case "check on a non-EVM chain SKIPs cleanly" zero "SKIP solana-devnet - chainFamily svm" -- \
    sync_script --sig "check(string)" solana-devnet

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
    "ccipBnM": "0x0000000000000000000000000000000000000000",
    "ccip": {}
}
EOF
run_case "wrong selector -> SELECTOR MISMATCH naming both chainIds" nonzero \
    "SELECTOR MISMATCH for tooling-tmp: config says chainId 99999 but the selector resolves to chainId 11155111" -- \
    sync_script --sig "run(string)" "$TMP_CHAIN"

# 6b. right chainId+selector but a NON-canonical name -> SELECTOR NAME MISMATCH (the selectorName
#     guard: the config `name` must equal the CCIP registry/API selectorName). chainId matches so the
#     chainId guard passes and the NAME guard is the one that fires.
python3 -c "
import json
d = json.load(open('$TMP_FILE'))
d['chainId'] = '11155111'; d['name'] = 'ethereum-sepolia'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
run_case "non-canonical name -> SELECTOR NAME MISMATCH names the canonical selectorName" nonzero \
    "SELECTOR NAME MISMATCH for tooling-tmp: config name 'ethereum-sepolia' is not the canonical selectorName" -- \
    sync_script --sig "run(string)" "$TMP_CHAIN"

# 7. unknown selector -> NOT_FOUND from the fetch script, surfaced as the revert reason
python3 -c "
import json
d = json.load(open('$TMP_FILE')); d['chainSelector'] = '123'; json.dump(d, open('$TMP_FILE','w'), indent=4)
"
run_case "unknown selector -> named NOT_FOUND error" nonzero "NOT_FOUND: no chain for selector 123" -- \
    sync_script --sig "run(string)" "$TMP_CHAIN"
rm -f "$TMP_FILE"

# 7b. add-chain enforces the selectorName too: a non-canonical CHAIN name for a real selector fails
#     up front (this is the guard path that also validates non-EVM chains, whose chainId is "0").
run_case "add-chain rejects a non-canonical name -> SELECTOR NAME MISMATCH" nonzero \
    "SELECTOR NAME MISMATCH for ethereum-sepolia: config name 'ethereum-sepolia' is not the canonical selectorName" -- \
    sync_script --sig "init(string,uint256)" ethereum-sepolia "$SEPOLIA_SELECTOR"

# 7c. add-chain PRINTS the exact derived env-var names so the operator never has to guess (or open
#     the JSON) which var to export. Uses a real, non-bundled chain (Fuji) whose UPPER_SNAKE-derived
#     AVALANCHE_TESTNET_FUJI differs from a curated short form; the generated config is a throwaway
#     removed here and in cleanup(). Asserts BOTH the chainNameIdentifier and the rpcEnv line.
rm -f "$FUJI_FILE"
out="$(sync_script --sig "init(string,uint256)" "$FUJI_CHAIN" "$FUJI_SELECTOR" 2>&1)"
if echo "$out" | grep -q "chainNameIdentifier: AVALANCHE_TESTNET_FUJI" &&
    echo "$out" | grep -q "rpcEnv: *AVALANCHE_TESTNET_FUJI_RPC_URL"; then
    pass=$((pass + 1))
    echo "[PASS] add-chain prints the generated chainNameIdentifier + rpcEnv names"
else
    fail=$((fail + 1))
    failures+=("add-chain prints env-var names")
    echo "[FAIL] add-chain prints env-var names (missing chainNameIdentifier/rpcEnv line)"
    echo "$out" | tail -8 | sed 's/^/       | /'
fi
rm -f "$FUJI_FILE"

# 8. API down (CCIP_API_BASE override) -> distinct API_UNREACHABLE error
run_case "API down -> named API_UNREACHABLE error" nonzero "API_UNREACHABLE" -- \
    env CCIP_API_BASE=http://127.0.0.1:1 bash -c \
    'FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig "run(string)" ethereum-testnet-sepolia-mantle-1'

# ---------------------------------------------------------------- sync-check exit contract (0/1/2)

# 9. clean chain -> exit 0 (live API)
run_case "sync-check clean chain exits 0" zero "CLEAN" -- \
    bash script/config/sync-check.sh ethereum-testnet-sepolia-mantle-1

# 10. drift (mutated router on a throwaway COPY of ethereum-testnet-sepolia) -> exit 1 + DRIFT line
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['ccip']['router'] = '0x0000000000000000000000000000000000000001'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
out="$(bash script/config/sync-check.sh "$TMP_CHAIN" 2>&1)"
status=$?
if [ $status -eq 1 ] && echo "$out" | grep -q "DRIFT tooling-tmp .ccip.router"; then
    pass=$((pass + 1))
    echo "[PASS] sync-check classifies drift as exit 1 + DRIFT line"
else
    fail=$((fail + 1))
    failures+=("sync-check drift")
    echo "[FAIL] sync-check drift (exit=$status)"
    echo "$out" | tail -6 | sed 's/^/       | /'
fi

# 11. API down -> exit 2 (flake, not drift)
out="$(CCIP_API_BASE=http://127.0.0.1:1 bash script/config/sync-check.sh "$TMP_CHAIN" 2>&1)"
status=$?
if [ $status -eq 2 ] && echo "$out" | grep -q "API_UNREACHABLE"; then
    pass=$((pass + 1))
    echo "[PASS] sync-check classifies API-down as exit 2"
else
    fail=$((fail + 1))
    failures+=("sync-check api-down")
    echo "[FAIL] sync-check api-down (exit=$status)"
    echo "$out" | tail -6 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE"

# ---------------------------------------------------------------- fixture transform (offline)

# Serve the committed API fixture from a local http.server so the REAL pipeline (curl + jq select +
# Solidity vm.writeJson) runs offline: GET /chains/<selector> -> the committed real response.
server_dir="$(mktemp -d)"
mkdir -p "$server_dir/chains"
cp "$FIXTURE" "$server_dir/chains/$SEPOLIA_SELECTOR"
port=$((20000 + RANDOM % 20000))
python3 -m http.server "$port" --directory "$server_dir" > /dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$port/chains/$SEPOLIA_SELECTOR" && break
    sleep 0.5
done

# 12. sync-config against the fixture server: ccip{} rewritten from the fixture's isActive entries,
#     every non-ccip key preserved, and a SECOND run leaves the file byte-identical (idempotency).
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
if echo "$out" | grep -q "TRANSFORM_OK"; then
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

# 12b. API-served fields sourced from the API: a HAND-EDITED displayName/environment/explorerUrl/
#      nativeCurrencySymbol is CORRECTED to the API value on sync, while the genuinely hand-authored
#      keys (confirmations, ccipBnM, rpcEnv, chainNameIdentifier) survive VERBATIM. This is the
#      one-writer-per-field guarantee for the widened synced surface.
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
  "ccipBnM": "0x000000000000000000000000000000000000dEaD",
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
assert d['ccipBnM'].lower() == '0x000000000000000000000000000000000000dead', ('ccipBnM clobbered', d['ccipBnM'])
assert d['rpcEnv'] == 'CUSTOM_HAND_RPC_URL', ('rpcEnv clobbered', d['rpcEnv'])
assert d['chainNameIdentifier'] == 'CUSTOM_HAND_ID', ('chainNameIdentifier clobbered', d['chainNameIdentifier'])
print('SOURCE_OK')
" 2>&1)"
if echo "$out" | grep -q "SOURCE_OK"; then
    pass=$((pass + 1))
    echo "[PASS] sync sources API-served fields + preserves hand-authored keys verbatim"
else
    fail=$((fail + 1))
    failures+=("metadata sourcing")
    echo "[FAIL] metadata sourcing: $out"
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
if [ $status -eq 1 ] && echo "$out" | grep -q "DRIFT tooling-tmp .explorerUrl"; then
    pass=$((pass + 1))
    echo "[PASS] sync-check catches metadata drift (.explorerUrl) as exit 1 + DRIFT line"
else
    fail=$((fail + 1))
    failures+=("metadata drift check")
    echo "[FAIL] metadata drift check (exit=$status, expected 1 + /DRIFT tooling-tmp .explorerUrl/)"
    echo "$out" | tail -6 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE"

# 13. sync-check against the fixture server -> CLEAN exit 0 (offline check path). The throwaway is a
#     copy of the committed sepolia file (name stays the canonical selectorName so the guard passes),
#     so every synced field (ccip{} + metadata) already matches the fixture.
cp config/chains/ethereum-testnet-sepolia.json "$TMP_FILE"
run_case "fixture sync-check: clean against the fixture server" zero "CLEAN" -- \
    env CCIP_API_BASE="http://127.0.0.1:$port" bash script/config/sync-check.sh "$TMP_CHAIN"
rm -f "$TMP_FILE"

# ---------------------------------------------------------------- check-chain doctor

# 14. unknown chain -> attributed FAIL + nonzero verdict
run_case "check-chain unknown chain FAILs with the add-chain hint" nonzero "config: no config/chains/doesnotexist" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" doesnotexist

# 15. non-EVM chain -> schema parse only, 0 FAIL
run_case "check-chain on solana-devnet passes (non-EVM path)" zero "0 FAIL" -- \
    env FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" solana-devnet

# 16. EVM chain with rpcEnv unset -> rpc SKIP (not FAIL), overall 0 FAIL (live API for the drift rung)
run_case "check-chain SKIPs rpc when the rpcEnv var is unset" zero "\[SKIP\] rpc: env MANTLE_SEPOLIA_RPC_URL unset" -- \
    env -u MANTLE_SEPOLIA_RPC_URL FOUNDRY_PROFILE=sync \
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
python3 -c "
import json
d = json.load(open('config/chains/ethereum-testnet-sepolia.json'))
d['ccip']['router'] = '0x0000000000000000000000000000000000000001'
json.dump(d, open('$TMP_FILE','w'), indent=4)
"
out="$(make sync-check CHAIN="$TMP_CHAIN" 2>&1)"
status=$?
if [ $status -eq 2 ] && echo "$out" | grep -q "CONFIG_DRIFT"; then
    pass=$((pass + 1))
    echo "[PASS] make sync-check remaps the script's drift exit 1 to make exit 2 (pass/fail only)"
else
    fail=$((fail + 1))
    failures+=("make sync-check remap")
    echo "[FAIL] make sync-check remap (exit=$status, expected 2 + /CONFIG_DRIFT/)"
    echo "$out" | tail -6 | sed 's/^/       | /'
fi
rm -f "$TMP_FILE"

# ---------------------------------------------------------------- canonical config format

# 19. the canonical-format guarantee: committed configs ARE canon (fmt-config -> no diff vs the git
#     index), fmt-config is idempotent (second run byte-identical), and a real live `make sync` on a
#     clean chain yields ZERO git diff (the recipe re-canonicalizes vm.writeJson's output).
run_case "make fmt-config runs clean" zero "canonicalized" -- \
    make fmt-config
if git diff --exit-code --quiet -- config/chains/; then
    pass=$((pass + 1))
    echo "[PASS] fmt-config: committed configs are already canonical (zero git diff)"
else
    fail=$((fail + 1))
    failures+=("fmt-config committed==canon")
    echo "[FAIL] fmt-config: committed configs are NOT canonical (git diff below)"
    git diff --stat -- config/chains/ | sed 's/^/       | /'
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

# 20. live zero-diff sync: with sync-check CLEAN (no value drift), `make sync` must be byte-identical
#     to the committed file — this is the no-churn guarantee the canonical format exists for.
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

echo ""
echo "== test-tooling: $pass passed, $fail failed =="
if [ $fail -ne 0 ]; then
    printf 'failed: %s\n' "${failures[@]}"
    exit 1
fi
