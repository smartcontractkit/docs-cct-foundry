// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {CcipApiSource} from "../../src/config/CcipApiSource.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

/// @dev External try/catch targets for `VerifyChain` (forge forbids `this.` self-calls in ephemeral
/// script contracts). Deployed by the script, so it inherits cheatcode access; reverts from the real
/// `ChainConfig` parse paths / fork cheatcodes become catchable, attributed FAILs.
contract ChainProbe {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function parseChain(string memory name) external view returns (ChainConfig.Chain memory) {
        return ChainConfig.load(name);
    }

    function parseQuotedDecimals(string memory json) external pure returns (string memory, string memory) {
        return (VM.parseJsonString(json, ".chainId"), VM.parseJsonString(json, ".chainSelector"));
    }

    function fetchFlat(uint64 selector) external returns (string memory) {
        return (new CcipApiSource()).fetchActiveCcipConfig(selector);
    }

    function forkTo(string memory rpcUrl) external returns (uint256) {
        VM.createSelectFork(rpcUrl);
        return block.chainid;
    }

    /// @dev The pool CCIP actually routes through for `token`, read from the on-chain
    /// TokenAdminRegistry. External so a revert (no TAR entry / RPC hiccup) is catchable by VerifyChain.
    function wiredPool(address tokenAdminRegistry, address token) external view returns (address) {
        return TokenAdminRegistry(tokenAdminRegistry).getPool(token);
    }
}

/// @title VerifyChain
/// @notice The layered chain-config doctor. One aligned [PASS]/[FAIL]/[WARN]/[SKIP] line per check,
/// reverting at the end iff any FAIL, so a chain can be verified end-to-end between "config file
/// edited" and "scripts run against it". Layers:
///   1. TOOLS     curl + jq present (the ffi fetch preflight)
///   2. SCHEMA    every key the real `ChainConfig.load` path consumes, incl. the quoted-decimal
///                big-int rule, plus an actual `ChainConfig.load` parse
///   3. API       re-fetch via the config-sync seam: selector<->chainId identity + field drift
///                (WARN + skip when the API is unreachable — flake is not failure)
///   4. RPC       rpcEnv set (SKIP cleanly when unset) -> fork -> block.chainid == chainId
///   5. ON-CHAIN  code present for router/rmnProxy/tokenAdminRegistry/registryModuleOwnerCustom/link
///                on the fork (proves the addresses belong on this chain)
///   6. REGISTRY  `addresses/<chainId>.json` token/tokenPool entries (WARN while undeployed) and
///                review-me extras (explorerUrl/nativeCurrencySymbol/ccipBnM) — WARNs, not FAILs
///
/// Run: FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" <name>
/// @dev Non-EVM chains (e.g. solana-devnet) get the schema parse only; API/RPC/on-chain/registry
/// rungs are skipped (destination-only support, zeroed `ccip{}` by design).
contract VerifyChain is Script {
    uint256 private fails;
    uint256 private warns;
    bool private forked;
    ChainProbe private probe;

    function _pass(string memory msg_) private pure {
        console.log(string.concat("[PASS] ", msg_));
    }

    function _fail(string memory msg_) private {
        fails++;
        console.log(string.concat("[FAIL] ", msg_));
    }

    function _warn(string memory msg_) private {
        warns++;
        console.log(string.concat("[WARN] ", msg_));
    }

    function _skip(string memory msg_) private pure {
        console.log(string.concat("[SKIP] ", msg_));
    }

    function _path(string memory name) private pure returns (string memory) {
        return string.concat("config/chains/", name, ".json");
    }

    function run(string memory name) public {
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("sync")),
            "run with FOUNDRY_PROFILE=sync (enables ffi): FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig \"run(string)\" <name>"
        );
        console.log(string.concat("== check-chain ", name, " =="));
        probe = new ChainProbe();

        _checkTools();

        string memory path = _path(name);
        if (!vm.exists(path)) {
            _fail(
                string.concat(
                    "config: no ",
                    path,
                    " - new chain? FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"init(string,uint256)\" ",
                    name,
                    " <chainSelector>"
                )
            );
            _verdict(name);
            return;
        }
        string memory json = vm.readFile(path);
        bool isEvm = _checkSchema(name, json);
        if (isEvm) {
            _checkApi(name, json);
            bool rpcOk = _checkRpc(json);
            if (rpcOk) _checkOnChainCode(name, json);
            _checkRegistryAndExtras(name, json);
        } else {
            // Non-EVM chains have no EVM-shaped ccip{} to sync, so the API/RPC/on-chain/registry
            // rungs are skipped — but the selectorName IS validatable for every family (chainId is a
            // placeholder "0" here, so it is the only identity the doctor can check).
            _checkSelectorNameNonEvm(json);
            _skip("rpc/on-chain/registry: non-EVM chain (destination-only support) - schema + selectorName only");
        }
        _verdict(name);
    }

    function _verdict(string memory name) private view {
        console.log(
            string.concat("== check-chain ", name, ": ", vm.toString(fails), " FAIL, ", vm.toString(warns), " WARN ==")
        );
        require(fails == 0, string.concat("check-chain FAILED for ", name, " - see [FAIL] lines above"));
    }

    // ---------------------------------------------------------------- 1. TOOLS
    function _checkTools() private {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-lc";
        cmd[2] = "command -v curl >/dev/null && command -v jq >/dev/null";
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode == 0) _pass("tools: curl + jq present");
        else _fail("tools: curl and/or jq missing - install them (brew install curl jq)");
    }

    // ---------------------------------------------------------------- 2. SCHEMA
    function _checkSchema(string memory name, string memory json) private returns (bool isEvm) {
        if (!vm.keyExistsJson(json, ".chainFamily")) {
            _fail("schema: missing .chainFamily");
            return false;
        }
        isEvm = keccak256(bytes(vm.parseJsonString(json, ".chainFamily"))) == keccak256(bytes("evm"));

        // quoted-decimal big-int rule (bare JSON numbers lose precision above 2^53)
        try probe.parseQuotedDecimals(json) {
            _pass("schema: chainId + chainSelector are quoted decimal strings");
        } catch {
            _fail("schema: chainId/chainSelector must be quoted decimal STRINGS (see config/chains/*.json)");
        }

        string[18] memory required = [
            ".name",
            ".displayName",
            ".chainNameIdentifier",
            ".chainId",
            ".chainSelector",
            ".rpcEnv",
            ".confirmations",
            ".explorerUrl",
            ".nativeCurrencySymbol",
            ".ccipBnM",
            ".ccip.router",
            ".ccip.rmnProxy",
            ".ccip.tokenAdminRegistry",
            ".ccip.registryModuleOwnerCustom",
            ".ccip.link",
            ".ccip.feeQuoter",
            ".ccip.tokenPoolFactory",
            ".ccip.feeTokens"
        ];
        uint256 missing = 0;
        for (uint256 i = 0; i < required.length; i++) {
            if (!vm.keyExistsJson(json, required[i])) {
                _fail(string.concat("schema: missing key ", required[i]));
                missing++;
            }
        }
        if (missing == 0) _pass("schema: all keys consumed by ChainConfig.load + the sync tooling present");

        try probe.parseChain(name) {
            _pass("schema: ChainConfig.load parses (the real read path)");
        } catch Error(string memory reason) {
            _fail(string.concat("schema: ChainConfig.load reverts - ", reason));
        } catch {
            _fail("schema: ChainConfig.load reverts (cheatcode parse error - check value formats)");
        }
    }

    // ---------------------------------------------------------------- 3. API
    function _checkApi(string memory name, string memory json) private {
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));
        string memory flat;
        try probe.fetchFlat(selector) returns (string memory f) {
            flat = f;
        } catch Error(string memory reason) {
            _warn(string.concat("api: fetch failed - drift check skipped: ", reason));
            return;
        } catch {
            _warn("api: fetch failed - drift check skipped");
            return;
        }
        // selector <-> chainId identity (a valid-but-wrong selector is the worst silent failure)
        uint256 localChainId = vm.parseJsonUint(json, ".chainId");
        uint256 apiChainId = vm.parseJsonUint(flat, ".chainId");
        string memory apiName = vm.parseJsonString(flat, ".apiName");
        if (localChainId == apiChainId) {
            _pass(string.concat("api: selector ", vm.toString(selector), " resolves to this chainId (", apiName, ")"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR MISMATCH - config chainId ",
                    vm.toString(localChainId),
                    " but selector is chainId ",
                    vm.toString(apiChainId),
                    " (",
                    apiName,
                    ") - fix .chainSelector"
                )
            );
            return;
        }
        // selectorName identity: the config `name` must be the canonical CCIP selectorName (the
        // universal key shared by the API, CLD, Atlas, and ccip-cli) for this selector.
        string memory localName = vm.parseJsonString(json, ".name");
        if (keccak256(bytes(localName)) == keccak256(bytes(apiName))) {
            _pass(string.concat("api: config name '", localName, "' matches the canonical selectorName"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR NAME MISMATCH - config name '",
                    localName,
                    "' but the selector's canonical selectorName is '",
                    apiName,
                    "' - set .name and rename the file to ",
                    apiName,
                    ".json"
                )
            );
        }
        // field drift vs the stored ccip{} block (same key list the sync writes)
        string[7] memory keys = [
            "router",
            "rmnProxy",
            "tokenAdminRegistry",
            "registryModuleOwnerCustom",
            "link",
            "feeQuoter",
            "tokenPoolFactory"
        ];
        uint256 drift = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            address cur = vm.parseJsonAddress(json, string.concat(".ccip.", keys[i]));
            address live = vm.parseJsonAddress(flat, string.concat(".", keys[i]));
            if (cur != live) {
                _fail(string.concat("api: DRIFT .ccip.", keys[i], " ", vm.toString(cur), " -> ", vm.toString(live)));
                drift++;
            }
        }
        if (drift == 0) {
            _pass("api: .ccip matches the live API (no drift)");
        } else {
            _fail(
                string.concat(
                    "api: ",
                    vm.toString(drift),
                    " field(s) drifted - refresh: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" ",
                    name
                )
            );
        }
    }

    /// @dev Non-EVM selectorName rung: fetch the chain-list identity row by selector and assert the
    /// config `name` equals the canonical selectorName. Uses the same meta helper the sync's
    /// add-chain path uses (works for every family). API flake is a WARN, not a FAIL.
    function _checkSelectorNameNonEvm(string memory json) private {
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "script/config/ccip-chain-meta.sh";
        cmd[2] = vm.toString(uint256(selector));
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode != 0) {
            _warn("api: selectorName check skipped - chain metadata fetch failed (flake, not config error)");
            return;
        }
        string memory apiName = vm.parseJsonString(string(r.stdout), ".apiName");
        string memory localName = vm.parseJsonString(json, ".name");
        if (keccak256(bytes(localName)) == keccak256(bytes(apiName))) {
            _pass(string.concat("api: config name '", localName, "' matches the canonical selectorName"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR NAME MISMATCH - config name '",
                    localName,
                    "' but the selector's canonical selectorName is '",
                    apiName,
                    "' - set .name and rename the file to ",
                    apiName,
                    ".json"
                )
            );
        }
    }

    // ---------------------------------------------------------------- 4. RPC
    function _checkRpc(string memory json) private returns (bool ok) {
        string memory rpcEnv = vm.parseJsonString(json, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        if (bytes(url).length == 0) {
            _skip(string.concat("rpc: env ", rpcEnv, " unset - add it to your .env to enable fork checks"));
            return false;
        }
        try probe.forkTo(url) returns (uint256 forkChainId) {
            uint256 expected = vm.parseJsonUint(json, ".chainId");
            if (forkChainId == expected) {
                forked = true;
                _pass(string.concat("rpc: ", rpcEnv, " reachable, block.chainid == ", vm.toString(expected)));
                return true;
            }
            _fail(
                string.concat(
                    "rpc: ",
                    rpcEnv,
                    " points at chainId ",
                    vm.toString(forkChainId),
                    " but config says ",
                    vm.toString(expected),
                    " (wrong network in .env?)"
                )
            );
        } catch {
            _fail(string.concat("rpc: could not fork via ", rpcEnv, " - endpoint down or URL invalid"));
        }
        return false;
    }

    // ---------------------------------------------------------------- 5. ON-CHAIN
    function _checkOnChainCode(string memory name, string memory json) private {
        if (!forked) return;
        string[5] memory keys = ["router", "rmnProxy", "tokenAdminRegistry", "registryModuleOwnerCustom", "link"];
        uint256 bad = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            address a = vm.parseJsonAddress(json, string.concat(".ccip.", keys[i]));
            if (a.code.length == 0) {
                _fail(
                    string.concat(
                        "on-chain: .ccip.", keys[i], " ", vm.toString(a), " has NO code on ", name, " (wrong chain?)"
                    )
                );
                bad++;
            }
        }
        if (bad == 0) {
            _pass("on-chain: router/rmnProxy/tokenAdminRegistry/registryModuleOwnerCustom/link all have code");
        }
    }

    // ---------------------------------------------------------------- 6. REGISTRY + EXTRAS
    function _checkRegistryAndExtras(string memory name, string memory json) private {
        uint256 chainId = vm.parseJsonUint(json, ".chainId");

        address token = RegistryWriter.read(chainId, "token");
        address pool = RegistryWriter.read(chainId, "tokenPool");
        if (token == address(0)) {
            _warn(
                string.concat(
                    "registry: no token in addresses/",
                    vm.toString(chainId),
                    ".json - deploy one (script/deploy/DeployToken.s.sol) or export {CHAIN}_TOKEN"
                )
            );
        } else if (forked && token.code.length == 0) {
            _fail(string.concat("registry: token ", vm.toString(token), " has NO code on ", name));
        } else {
            _pass(string.concat("registry: token ", vm.toString(token), forked ? " (has code)" : " (set; no fork)"));
        }
        if (pool == address(0)) {
            _warn(
                string.concat(
                    "registry: no tokenPool in addresses/", vm.toString(chainId), ".json - deploy one before Step 3+"
                )
            );
        } else if (forked && pool.code.length == 0) {
            _fail(string.concat("registry: tokenPool ", vm.toString(pool), " has NO code on ", name));
        } else {
            _pass(string.concat("registry: tokenPool ", vm.toString(pool), forked ? " (has code)" : " (set; no fork)"));
        }

        // Reconcile the registry's pool against the ON-CHAIN TokenAdminRegistry. `active.tokenPool` is
        // "what this repo deployed most recently"; the TAR is "the pool CCIP actually routes through".
        // They legitimately diverge whenever the wired pool was changed out-of-band (the TAR was pointed
        // at a different pool outside this repo's scripts), so this is always a WARN, never a FAIL.
        if (token != address(0) && pool != address(0)) {
            // Read the TAR address INSIDE the defensive path: a config missing `.ccip.tokenAdminRegistry`
            // must degrade to a WARN, not revert the whole doctor with a raw parse error (the missing key
            // is already reported by the schema rung above). Only reconcile when the key is present.
            if (vm.keyExistsJson(json, ".ccip.tokenAdminRegistry")) {
                _reconcilePoolWithTar(vm.parseJsonAddress(json, ".ccip.tokenAdminRegistry"), token, pool);
            } else {
                _warn(
                    "registry: .ccip.tokenAdminRegistry missing - cannot reconcile the registry pool against on-chain wiring"
                );
            }
        }

        // Extras (WARN, never FAIL). explorerUrl/nativeCurrencySymbol are API-sourced by the sync, so
        // empty means the API served none for this chain - re-run `make sync` or fill by hand. ccipBnM
        // is genuinely hand-authored (no CCIP token API) and optional.
        if (bytes(vm.parseJsonString(json, ".explorerUrl")).length == 0) {
            _warn("extras: explorerUrl is empty - run `make sync` (it is sourced from chainMetadata.explorer.url)");
        }
        if (bytes(vm.parseJsonString(json, ".nativeCurrencySymbol")).length == 0) {
            _warn(
                "extras: nativeCurrencySymbol is empty - run `make sync` (sourced from chainMetadata.nativeCurrency.symbol)"
            );
        }
        if (vm.parseJsonAddress(json, ".ccipBnM") == address(0)) {
            _warn("extras: ccipBnM is 0x0 - optional, hand-authored (only needed when using the CCIP test token)");
        }
    }

    /// @dev Registry-pool vs on-chain-TAR reconciliation (WARN-only). Needs an RPC (skips when not
    /// forked). Defensive: a token with no TAR entry / an RPC hiccup degrades to a WARN, never an
    /// unhandled revert that would kill the whole doctor run.
    function _reconcilePoolWithTar(address tar, address token, address pool) private {
        if (!forked) {
            _skip(
                "registry: TAR reconciliation needs an RPC (no fork) - registry pool not checked against on-chain wiring"
            );
            return;
        }
        try probe.wiredPool(tar, token) returns (address wired) {
            if (wired == pool) {
                _pass(
                    string.concat(
                        "registry: tokenPool ", vm.toString(pool), " is the pool wired in the TokenAdminRegistry"
                    )
                );
            } else if (wired == address(0)) {
                _warn(
                    string.concat(
                        "registry: token ",
                        vm.toString(token),
                        " has no pool registered in the TokenAdminRegistry - run script/setup/SetPool.s.sol"
                    )
                );
            } else {
                _warn(
                    string.concat(
                        "registry: tokenPool ",
                        vm.toString(pool),
                        " is NOT the wired pool (",
                        vm.toString(wired),
                        ") - the wired pool was changed out-of-band; otherwise the registry pointer is stale"
                    )
                );
            }
        } catch {
            _warn(
                string.concat(
                    "registry: could not read the TokenAdminRegistry (",
                    vm.toString(tar),
                    ") for token ",
                    vm.toString(token),
                    " - RPC hiccup or no TAR entry; skipping the wired-pool reconciliation"
                )
            );
        }
    }

    /// @notice Test hook: runs ONLY the registry-vs-TAR reconciliation against the currently-selected
    /// fork and returns `(fails, warns)`. Lets a fork test assert the WARN-not-FAIL contract (divergence
    /// must never increment `fails`) without the full ffi/API doctor run. Not used by any production path.
    function reconcilePoolWithTarForTest(address tar, address token, address pool)
        public
        returns (uint256 failsOut, uint256 warnsOut)
    {
        forked = true;
        probe = new ChainProbe();
        _reconcilePoolWithTar(tar, token, pool);
        return (fails, warns);
    }
}
