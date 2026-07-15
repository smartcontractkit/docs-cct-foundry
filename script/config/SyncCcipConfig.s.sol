// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {IConfigSource} from "../../src/config/IConfigSource.sol";
import {CcipApiSource} from "../../src/config/CcipApiSource.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title SyncCcipConfig
/// @notice The config-sync entrypoints: everything that generates, refreshes, or drift-checks a
/// `config/chains/<name>.json` file from the live CCIP REST API v2. JSON file generation stays
/// Foundry-side (`vm.serialize*` + `vm.writeJson`); the shell helpers only fetch + select.
///
/// All entrypoints require the `sync` foundry profile (enables `ffi` for the curl/jq fetch):
///   - add a chain:   FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol \
///                      --sig "init(string,uint256)" <local-name> <chainSelector>
///   - refresh ccip{}: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol \
///                      --sig "run(string)" <local-name>
///   - preview (no write): ... --sig "preview(string)" <local-name>
///   - drift check (read-only): ... --sig "check(string)" <local-name>
///     (or `bash script/config/sync-check.sh`, which owns the 0 clean / 1 drift / 2 api-down
///      exit-code contract across all configured chains)
///   - add a lane:    ... --sig "addLane(string,string,uint256,uint256)" <local> <remote> <cap> <rate>
///     (`make add-lane` — writes ONLY the `lanes{}` policy subtree; no API fetch); with an inbound
///     policy block: --sig "addLane(string,string,uint256,uint256,uint256,uint256)" ... <inCap> <inRate>
///     (`make add-lane ... INBOUND_CAPACITY=<wei> INBOUND_RATE=<wei>`)
///
/// @dev What the sync OWNS (overwrites): every API-served field. That is the `ccip{}` object — the
/// API-syncable, directory-canonical addresses (`router`, `rmnProxy`, `tokenAdminRegistry`,
/// `registryModuleOwnerCustom`, `link`, `feeQuoter`, `tokenPoolFactory`, `feeTokens[]`) — AND the
/// API-served identity + metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`,
/// `nativeCurrencySymbol`), all of which `GET /v2/chains/{selector}` serves, so none is hand-typed.
/// What it PRESERVES (never touches): the THREE genuinely hand-authored keys the API serves nothing for
/// (`chainNameIdentifier`, `rpcEnv`, `confirmations`) and the immutable join keys
/// (`name`/`chainSelector`/`chainId`) which are GUARD-validated, not rewritten. One writer per field.
/// Project state (`lanes{}`, `roles{}`, deployed `addresses{}`) is NOT in this file — it lives in
/// `project/<selectorName>.json`, so the sync never touches it (config/chains is pure API/chain facts).
///
/// Guards (each verified by `script/config/test-tooling.sh`):
///   - SELECTOR MISMATCH: after every fetch the API's chainId must equal the local file's chainId —
///     a wrong-but-valid selector can never silently write another chain's contracts.
///   - non-EVM SKIP: non-EVM chain families (e.g. solana-devnet) skip the EVM `ccip{}` transform — an
///     SVM file keeps its zeroed `ccip{}` block — but their chain-level identity + metadata (served
///     for every family) ARE validated + refreshed. The guard is Solidity-side so every entrypoint
///     is covered.
///   - chain-name validation: config names become file paths and shell arguments, so `init` only
///     accepts `[a-z0-9][a-z0-9-]*` (no path traversal, no spaces).
contract SyncCcipConfig is Script {
    string private constant META_HELPER = "script/config/ccip-chain-meta.sh";

    /// @notice The active config source. Swap this to target a different API version/source.
    /// Virtual so a test can substitute an offline source behind the same seam.
    function _source() internal virtual returns (IConfigSource) {
        return new CcipApiSource();
    }

    function _path(string memory name) internal pure returns (string memory) {
        return string.concat("config/chains/", name, ".json");
    }

    /// @dev All entrypoints need ffi, which only the `sync` profile grants. Failing early with the
    /// real fix beats forge's misleading "--ffi" advice.
    function _requireSyncProfile() internal view {
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("sync")),
            "run with FOUNDRY_PROFILE=sync (enables ffi): FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig ..."
        );
    }

    /// @dev Non-EVM guard, Solidity-side so no invocation path can inject an EVM `ccip{}` block
    /// into a non-EVM file (the EVM transform would die on the missing contract entries anyway).
    function _skipNonEvm(string memory name, string memory json) internal pure returns (bool) {
        string memory fam = vm.parseJsonString(json, ".chainFamily");
        if (keccak256(bytes(fam)) != keccak256(bytes("evm"))) {
            console.log(
                string.concat("[sync] SKIP ", name, " - chainFamily ", fam, " is not EVM-syncable (non-EVM chain)")
            );
            return true;
        }
        return false;
    }

    /// @dev Unknown chain -> a helpful list of the configured chains, never a raw cheatcode revert.
    function _requireConfigExists(string memory name) internal view returns (string memory path) {
        path = _path(name);
        if (!vm.exists(path)) {
            revert(
                string.concat(
                    "[sync] no ",
                    path,
                    ". Known chains: ",
                    _knownChains(),
                    ". New chain? run: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"init(string,uint256)\" ",
                    name,
                    " <chainSelector>"
                )
            );
        }
    }

    /// @dev Comma-joined basenames of config/chains/*.json.
    function _knownChains() internal view returns (string memory list) {
        Vm.DirEntry[] memory entries = vm.readDir("config/chains");
        for (uint256 i = 0; i < entries.length; i++) {
            string memory base = _jsonBasename(entries[i].path);
            if (bytes(base).length == 0) continue;
            list = bytes(list).length == 0 ? base : string.concat(list, ", ", base);
        }
    }

    /// @dev "config/chains/ethereum-testnet-sepolia.json" -> "ethereum-testnet-sepolia" (empty for non-.json entries).
    function _jsonBasename(string memory filePath) internal pure returns (string memory) {
        bytes memory b = bytes(filePath);
        bytes memory suffix = bytes(".json");
        if (b.length < suffix.length) return "";
        for (uint256 i = 0; i < suffix.length; i++) {
            if (b[b.length - suffix.length + i] != suffix[i]) return "";
        }
        uint256 start = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "/") start = i + 1;
        }
        bytes memory out = new bytes(b.length - suffix.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /// @dev The SELECTOR MISMATCH guard: the API row fetched BY SELECTOR must describe the same
    /// chainId the local file claims — otherwise the selector is a valid-but-WRONG one and syncing
    /// would silently write another chain's contracts into this file. After the chainId check it
    /// also asserts the config `name` equals the canonical selectorName (`_requireSelectorName`).
    function _requireIdentity(string memory name, string memory localJson, string memory flat) internal pure {
        uint256 localChainId = vm.parseJsonUint(localJson, ".chainId");
        uint256 apiChainId = vm.parseJsonUint(flat, ".chainId");
        require(
            localChainId == apiChainId,
            string.concat(
                "[sync] SELECTOR MISMATCH for ",
                name,
                ": config says chainId ",
                vm.toString(localChainId),
                " but the selector resolves to chainId ",
                vm.toString(apiChainId),
                " (",
                vm.parseJsonString(flat, ".apiName"),
                ") - fix .chainSelector in config/chains/",
                name,
                ".json (script/config/sync-discover.sh lists valid selectors)"
            )
        );
        _requireSelectorName(name, vm.parseJsonString(localJson, ".name"), vm.parseJsonString(flat, ".apiName"));
    }

    /// @dev The SELECTOR NAME guard: the config's lowercase `name` MUST equal the canonical CCIP
    /// **selectorName** the chain-selectors registry (and the REST API `name` field) assign to this
    /// selector — the one universal key the CCIP API, CLD, Atlas, the directory URL leaf, and
    /// `ccip-cli` all share (e.g. `ethereum-testnet-sepolia`, not the bespoke `ethereum-sepolia`).
    /// Unlike the chainId guard this ALSO validates non-EVM chains, whose config carries a
    /// placeholder `chainId: "0"` the chainId check can never verify — for those the selectorName is
    /// the only real identity. `apiName` is the API `.chain.name` (== the registry `name`) the
    /// fetch helpers already surface, so no extra round-trip is needed on the EVM sync path.
    function _requireSelectorName(string memory name, string memory localName, string memory apiName) internal pure {
        require(
            keccak256(bytes(localName)) == keccak256(bytes(apiName)),
            string.concat(
                "[sync] SELECTOR NAME MISMATCH for ",
                name,
                ": config name '",
                localName,
                "' is not the canonical selectorName for this selector - the CCIP registry/API name is '",
                apiName,
                "'. Set .name to '",
                apiName,
                "' and rename the file to config/chains/",
                apiName,
                ".json (the config basename IS the selectorName)"
            )
        );
    }

    // ================================================================
    // preview / run — fetch + (optionally) write the ccip{} block
    // ================================================================

    /// @notice Fetch + log a chain's active CCIP config WITHOUT writing (dry run).
    function preview(string memory name) public returns (string memory flatJson) {
        _requireSyncProfile();
        string memory json = vm.readFile(_requireConfigExists(name));
        if (_skipNonEvm(name, json)) return "";
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));
        flatJson = _source().fetchActiveCcipConfig(selector);
        _requireIdentity(name, json, flatJson);
        console.log("[sync preview]", name, "selector", selector);
        console.log(flatJson);
    }

    /// @notice Sync ONE chain: overwrite its API-served fields from the API; preserve every
    /// hand-authored key. The API-sync writer now owns the `ccip{}` address block AND the API-served
    /// identity + metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`,
    /// `nativeCurrencySymbol`) — all of which the CCIP REST API serves, so none of them should be
    /// hand-typed. The three hand-authored keys (`chainNameIdentifier`, `rpcEnv`, `confirmations`) and
    /// the immutable join keys (`name`/`chainSelector`/`chainId`, guarded, not rewritten) are preserved
    /// untouched; project state (`lanes{}`/`roles{}`/`addresses{}`) is not in this file. Non-EVM chains
    /// have no EVM-shaped `chainConfig`, so their `ccip{}` block stays zeroed (SKIP), but their
    /// chain-level identity + metadata ARE served and get refreshed.
    function run(string memory name) public {
        _requireSyncProfile();
        string memory path = _requireConfigExists(name);
        string memory json = vm.readFile(path);
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));

        if (_skipNonEvm(name, json)) {
            // Non-EVM: no EVM-shaped ccip{} to sync, but the chain-level identity + metadata are
            // served for every family. Validate the selectorName (the only identity a "0"-chainId
            // non-EVM file can be checked on) and refresh the metadata fields from the API.
            string memory meta = _fetchChainMeta(selector);
            _requireSelectorName(name, vm.parseJsonString(json, ".name"), vm.parseJsonString(meta, ".apiName"));
            _refreshMetadata(path, meta);
            console.log(string.concat("[sync] refreshed identity metadata for ", name, " -> ", path));
            return;
        }

        string memory flat = _source().fetchActiveCcipConfig(selector);
        _requireIdentity(name, json, flat);

        // Refresh the API-served metadata fields, then replace ONLY the `.ccip` subtree; every
        // hand-authored key is preserved untouched (the merge rule).
        _refreshMetadata(path, flat);
        vm.writeJson(_buildCcipJson(name, flat), path, ".ccip");
        console.log(string.concat("[sync] wrote .ccip block + metadata for ", name, " -> ", path));
    }

    /// @notice THE single list of API-served metadata fields the sync MAINTAINS alongside `ccip{}`
    /// (shared by the `run` write and the `check` drift-compare). Every one is served by
    /// `GET /v2/chains/{selector}` — `displayName`/`chainFamily`/`environment` from `.chain`,
    /// `explorerUrl`/`nativeCurrencySymbol` from `.chainMetadata` — so none is hand-authored. NOT in
    /// this list (genuinely hand-authored, the API serves nothing for them): `chainNameIdentifier`,
    /// `rpcEnv`, `confirmations`.
    function metadataKeys() public pure returns (string[5] memory) {
        return ["displayName", "chainFamily", "environment", "explorerUrl", "nativeCurrencySymbol"];
    }

    /// @dev Overwrite each API-served metadata field in-place from the flat source JSON (which the
    /// EVM `ccip-config-source.sh` and the non-EVM `ccip-chain-meta.sh` both carry). Targeted
    /// `vm.writeJson(value, path, key)` writes preserve every other key. `chainFamily` arrives
    /// already lowercased from the fetcher, so a matching config does not churn.
    function _refreshMetadata(string memory path, string memory src) internal {
        string[5] memory keys = metadataKeys();
        for (uint256 i = 0; i < keys.length; i++) {
            string memory value = vm.parseJsonString(src, string.concat(".", keys[i]));
            // Write as a JSON string literal at the top-level key (values are controlled API strings
            // with no embedded quotes/backslashes: names, symbols, explorer URLs).
            vm.writeJson(string.concat("\"", value, "\""), path, string.concat(".", keys[i]));
        }
    }

    /// @dev Serialize the normalized flat source JSON into the `ccip` object (JSON generation stays
    /// Foundry-side). `check()` reuses the same field list via `ccipAddressKeys` so the drift check
    /// and the write can never diverge.
    function _buildCcipJson(string memory name, string memory flat) internal returns (string memory) {
        string memory obj = string.concat("ccip-", name);
        string[7] memory keys = ccipAddressKeys();
        for (uint256 i = 0; i < keys.length; i++) {
            vm.serializeAddress(obj, keys[i], vm.parseJsonAddress(flat, string.concat(".", keys[i])));
        }
        return vm.serializeAddress(obj, "feeTokens", vm.parseJsonAddressArray(flat, ".feeTokens"));
    }

    /// @notice THE single list of API-synced `ccip{}` address fields (shared by the `run` write and
    /// the `check` drift-compare; also pinned by the fixture test).
    function ccipAddressKeys() public pure returns (string[7] memory) {
        return [
            "router",
            "rmnProxy",
            "tokenAdminRegistry",
            "registryModuleOwnerCustom",
            "link",
            "feeQuoter",
            "tokenPoolFactory"
        ];
    }

    // ================================================================
    // init — add-chain: generate config/chains/<name>.json FROM the API
    // ================================================================

    /// @notice Generate `config/chains/<localName>.json` from the API row for `selector`, then sync
    /// its `ccip{}` block in the same invocation. The SELECTOR is the numeric lookup key; the
    /// supplied name MUST be the canonical CCIP selectorName the API/registry assign to that
    /// selector (`_requireSelectorName` enforces this for every family, incl. non-EVM), so the file
    /// basename and `.name` are always the universal selectorName (e.g. `ethereum-testnet-sepolia`).
    /// @dev Refuses to overwrite an existing file (refresh an existing chain with `run` instead).
    /// `chainNameIdentifier` defaults to UPPER_SNAKE(localName) and `rpcEnv` to
    /// `<chainNameIdentifier>_RPC_URL`; override per-run with the `CHAIN_NAME_IDENTIFIER` / `RPC_ENV`
    /// environment variables. Repo extras that the API does not carry (`confirmations`,
    /// `explorerUrl`, `nativeCurrencySymbol`) are written as review-me defaults.
    function init(string memory localName, uint256 selector) public {
        _requireSyncProfile();
        require(
            isValidChainName(localName),
            string.concat(
                "[add-chain] invalid chain name '",
                localName,
                "' - use lowercase letters, digits and dashes only ([a-z0-9][a-z0-9-]*); the name becomes a file path"
            )
        );
        string memory path = _path(localName);
        require(
            !vm.exists(path),
            string.concat(
                "[add-chain] ",
                path,
                " already exists - refusing to overwrite. Refresh it instead: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" ",
                localName
            )
        );

        string memory meta = _fetchChainMeta(selector);
        // The provided CHAIN name MUST be the canonical selectorName for this selector. This works
        // for EVERY family (the meta row carries `apiName` for EVM and non-EVM alike), so it closes
        // the non-EVM gap: a Solana/other non-EVM config has a placeholder `chainId: "0"` the
        // chainId guard can't verify, but its selectorName is fully validated here at creation.
        _requireSelectorName(localName, localName, vm.parseJsonString(meta, ".apiName"));
        string memory fam = vm.parseJsonString(meta, ".chainFamily");
        bool isEvm = keccak256(bytes(fam)) == keccak256(bytes("evm"));

        string memory chainNameId = vm.envOr("CHAIN_NAME_IDENTIFIER", string(""));
        if (bytes(chainNameId).length == 0) chainNameId = chainNameIdentifierFor(localName);
        string memory rpcEnv = vm.envOr("RPC_ENV", string(""));
        if (bytes(rpcEnv).length == 0) rpcEnv = string.concat(chainNameId, "_RPC_URL");

        string memory root = string.concat("chain-", localName);
        vm.serializeString(root, "name", localName);
        vm.serializeString(root, "displayName", vm.parseJsonString(meta, ".displayName"));
        vm.serializeString(root, "chainNameIdentifier", chainNameId);
        vm.serializeString(root, "chainFamily", fam);
        vm.serializeString(root, "environment", vm.parseJsonString(meta, ".environment"));
        // chainId: API-sourced for EVM; a "0" placeholder for non-EVM (the API's non-EVM chainId is a
        // base58/hash string, not the numeric id the repo keys addresses on — selectorName is the
        // portable identity there).
        vm.serializeString(root, "chainId", isEvm ? vm.parseJsonString(meta, ".chainId") : "0");
        vm.serializeString(root, "chainSelector", vm.parseJsonString(meta, ".chainSelector"));
        vm.serializeString(root, "rpcEnv", rpcEnv);
        // Genuinely hand-authored (the API serves nothing for it): confirmations (the block
        // confirmations the scripts wait for — user-overridable per chain, preserved by sync).
        // explorerUrl/nativeCurrencySymbol are seeded empty here but the `run(localName)` call below
        // sources them from the API's chainMetadata in the same invocation.
        vm.serializeUint(root, "confirmations", 2);
        vm.serializeString(root, "explorerUrl", "");
        vm.serializeString(root, "nativeCurrencySymbol", "");
        // `vm.writeJson` cannot CREATE keys, so the stub ships an (empty) ccip object the sync fills
        // below. lanes{}/roles{} + deployed addresses now live in project/<name>.json (seeded on the
        // first add-lane / snapshot-chain / deploy), NOT here: config/chains is pure API/chain facts.
        string memory stub = vm.serializeString(root, "ccip", "{}");
        vm.writeFile(path, stub);
        console.log(
            string.concat("[add-chain] generated ", path, " from API row ", vm.parseJsonString(meta, ".apiName"))
        );

        // fill .ccip in the same invocation (non-EVM chains get the SKIP log + keep the empty block).
        run(localName);

        _logNextSteps(localName, chainNameId, rpcEnv, isEvm);
    }

    /// @dev Fetch the chain-list row (identity metadata) by selector via the meta helper script.
    function _fetchChainMeta(uint256 selector) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = META_HELPER;
        cmd[2] = vm.toString(selector);
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode != 0) {
            revert(string(bytes.concat(bytes("[add-chain] chain metadata fetch failed: "), r.stderr)));
        }
        return string(r.stdout);
    }

    /// @notice Validates a local chain short name: `[a-z0-9][a-z0-9-]*`. Names become file paths
    /// (`config/chains/<name>.json`) and shell/script arguments, so anything else is refused.
    function isValidChainName(string memory name) public pure returns (bool) {
        bytes memory b = bytes(name);
        if (b.length == 0) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            bool lowerAlnum = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9");
            if (i == 0 ? !lowerAlnum : !(lowerAlnum || ch == "-")) return false;
        }
        return true;
    }

    /// @notice Derives the default `chainNameIdentifier` (the `{CHAIN}_*` env-var prefix) from the
    /// selectorName: UPPER_SNAKE, e.g. "ethereum-testnet-sepolia" -> "ETHEREUM_TESTNET_SEPOLIA".
    /// Review it — the repo usually prefers a shorter identifier (e.g. `ETHEREUM_SEPOLIA` /
    /// `ETHEREUM_SEPOLIA_RPC_URL`, or `0G_GALILEO_TESTNET` with `ZERO_G_TESTNET_RPC_URL`); override
    /// with `CHAIN_NAME_IDENTIFIER` / `RPC_ENV`.
    function chainNameIdentifierFor(string memory localName) public pure returns (string memory) {
        bytes memory b = bytes(localName);
        bytes memory out = new bytes(b.length);
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch == "-") out[i] = "_";
            else if (ch >= "a" && ch <= "z") out[i] = bytes1(uint8(ch) - 32);
            else out[i] = ch;
        }
        return string(out);
    }

    function _logNextSteps(string memory localName, string memory chainNameId, string memory rpcEnv, bool isEvm)
        internal
        view
    {
        bool rpcSet = bytes(vm.envOr(rpcEnv, string(""))).length != 0;
        console.log("");
        // Print the EXACT derived names: `chainNameIdentifier` is UPPER_SNAKE(selectorName) for newly
        // added chains, so it can differ in style from the bundled chains' curated short forms
        // (e.g. AVALANCHE_TESTNET_FUJI, not AVALANCHE_FUJI). Printing them saves the operator opening
        // the generated JSON to find which env var to export.
        console.log(string.concat("[add-chain] generated env-var names for ", localName, ":"));
        console.log(string.concat("  chainNameIdentifier: ", chainNameId));
        console.log(string.concat("  rpcEnv:              ", rpcEnv, "   <- export this to use RPC-dependent commands"));
        console.log("");
        console.log(string.concat("[add-chain] NEXT STEPS for ", localName, ":"));
        console.log(
            string.concat(
                "  1. RPC env var ",
                rpcEnv,
                rpcSet ? " (already set - nothing to do)" : " (UNSET - add it to your .env)"
            )
        );
        console.log(
            string.concat(
                "  2. review the generated defaults in config/chains/",
                localName,
                ".json: chainNameIdentifier, rpcEnv, confirmations, explorerUrl, nativeCurrencySymbol"
            )
        );
        if (isEvm) {
            console.log(
                "  3. no Solidity change needed - HelperConfig discovers the chain from config/chains/ automatically"
            );
            console.log(
                string.concat(
                    "  4. wire a lane: make add-lane LOCAL=",
                    localName,
                    " REMOTE=<remote> CAPACITY=<wei> RATE=<wei> [BOTH=1]"
                )
            );
            console.log(
                string.concat(
                    "  5. verify: FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig \"run(string)\" ",
                    localName,
                    " (re-run until it reports 0 FAIL)"
                )
            );
        } else {
            console.log("  3. non-EVM chain: the ccip{} block stays zeroed (destination-only support, see README)");
        }
    }

    // ================================================================
    // check — READ-ONLY drift detection (`bash script/config/sync-check.sh`)
    // ================================================================

    /// @notice Compare the on-disk `ccip{}` block field-by-field against the live API — NO writes.
    /// Reverts `CONFIG_DRIFT` if any field differs (greppable `DRIFT <chain> .ccip.<field>` lines
    /// first); a fetch failure reverts with the fetch script's named error (NOT_FOUND /
    /// API_UNREACHABLE), so `script/config/sync-check.sh` can classify its exit-code contract:
    /// 0 clean / 1 drift-or-config-error / 2 api-down.
    /// @dev Field-by-field via the same `vm.parseJson*` paths `ChainConfig.load` uses — never a
    /// string-compare of serialized JSON (key reordering would false-positive). Reuses
    /// `ccipAddressKeys` so check and write cannot diverge.
    function check(string memory name) public {
        _requireSyncProfile();
        string memory json = vm.readFile(_requireConfigExists(name));
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));

        if (_skipNonEvm(name, json)) {
            // Non-EVM: the ccip{} block is zeroed by design, but the chain-level identity + metadata
            // ARE served and drift-checkable. Validate the selectorName and diff the metadata fields.
            string memory meta = _fetchChainMeta(selector);
            _requireSelectorName(name, vm.parseJsonString(json, ".name"), vm.parseJsonString(meta, ".apiName"));
            uint256 metaDrift = _checkMetadata(name, json, meta);
            if (metaDrift > 0) {
                revert(
                    string.concat(
                        "CONFIG_DRIFT: ",
                        vm.toString(metaDrift),
                        " metadata field(s) drifted for ",
                        name,
                        " - refresh with: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" ",
                        name
                    )
                );
            }
            console.log(string.concat("[sync-check] CLEAN ", name, " - identity metadata matches the live API"));
            return;
        }

        string memory flat = _source().fetchActiveCcipConfig(selector);
        _requireIdentity(name, json, flat);

        uint256 drift = _checkMetadata(name, json, flat);
        string[7] memory keys = ccipAddressKeys();
        for (uint256 i = 0; i < keys.length; i++) {
            address cur = vm.parseJsonAddress(json, string.concat(".ccip.", keys[i]));
            address live = vm.parseJsonAddress(flat, string.concat(".", keys[i]));
            if (cur != live) {
                console.log(
                    string.concat("DRIFT ", name, " .ccip.", keys[i], " ", vm.toString(cur), " -> ", vm.toString(live))
                );
                drift++;
            }
        }
        drift += _checkFeeTokens(name, json, flat);

        if (drift > 0) {
            revert(
                string.concat(
                    "CONFIG_DRIFT: ",
                    vm.toString(drift),
                    " field(s) drifted for ",
                    name,
                    " - refresh with: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" ",
                    name
                )
            );
        }
        console.log(string.concat("[sync-check] CLEAN ", name, " - .ccip matches the live API"));
    }

    /// @dev Diff the API-served metadata fields (string values) against the flat source, one
    /// greppable `DRIFT <chain> .<field>` line per divergence. Reuses `metadataKeys` so the check and
    /// the `run` write can never diverge. Runs for BOTH families (identity metadata is served for all).
    function _checkMetadata(string memory name, string memory json, string memory src)
        internal
        pure
        returns (uint256 drift)
    {
        string[5] memory keys = metadataKeys();
        for (uint256 i = 0; i < keys.length; i++) {
            string memory cur = vm.parseJsonString(json, string.concat(".", keys[i]));
            string memory live = vm.parseJsonString(src, string.concat(".", keys[i]));
            if (keccak256(bytes(cur)) != keccak256(bytes(live))) {
                console.log(string.concat("DRIFT ", name, " .", keys[i], " '", cur, "' -> '", live, "'"));
                drift++;
            }
        }
    }

    function _checkFeeTokens(string memory name, string memory json, string memory flat)
        internal
        pure
        returns (uint256 drift)
    {
        address[] memory cur = vm.parseJsonAddressArray(json, ".ccip.feeTokens");
        address[] memory live = vm.parseJsonAddressArray(flat, ".feeTokens");
        if (cur.length != live.length) {
            console.log(
                string.concat(
                    "DRIFT ",
                    name,
                    " .ccip.feeTokens length ",
                    vm.toString(cur.length),
                    " -> ",
                    vm.toString(live.length)
                )
            );
            return 1;
        }
        for (uint256 i = 0; i < cur.length; i++) {
            if (cur[i] != live[i]) {
                console.log(
                    string.concat(
                        "DRIFT ",
                        name,
                        " .ccip.feeTokens[",
                        vm.toString(i),
                        "] ",
                        vm.toString(cur[i]),
                        " -> ",
                        vm.toString(live[i])
                    )
                );
                drift++;
            }
        }
    }

    // ================================================================
    // addLane — `make add-lane`: append a lanes{} policy entry
    // ================================================================

    /// @notice Append a `.lanes.<remote>` entry (remote selector + outbound rate-limit policy) to the
    /// LOCAL chain's config. Writes ONLY the `.lanes` subtree, with the same preserve-and-replace
    /// pattern `run` uses for `.ccip`: every existing lane entry is re-serialized verbatim, then the
    /// new entry is added and the subtree is written back in one `vm.writeJson(json, path, ".lanes")`.
    /// A duplicate lane is a logged no-op that leaves the file byte-identical. No API fetch: `lanes{}`
    /// is owner POLICY (which remotes this pool connects to, at what rate limits), not an API fact.
    /// @dev Guards:
    ///   - SELF-LANE: refused when LOCAL and REMOTE are the same name, or when two config files carry
    ///     the SAME chainSelector (a pool must never register its own selector as a remote).
    ///   - PLACEHOLDER POOL: a lane to a remote whose registry has no tokenPool yet logs a WARN naming
    ///     the missing deploy (the lane can be declared ahead of the deploy, but it is not executable).
    ///   - a local file without a `.lanes` object (non-EVM chains are destination-only and carry none)
    ///     is refused with the fix, never a raw cheatcode revert.
    function addLane(string memory local, string memory remote, uint256 capacity, uint256 rate) public {
        _addLane(
            local,
            remote,
            LanePolicy({capacity: capacity, rate: rate, withInbound: false, inboundCapacity: 0, inboundRate: 0})
        );
    }

    /// @notice `addLane` with an inbound rate-limit policy block
    /// (`make add-lane ... INBOUND_CAPACITY=<wei> INBOUND_RATE=<wei>`): writes the same entry plus
    /// `inbound{capacity,rate}`. A declared 0/0 inbound block means declared-DISABLED (the doctor's
    /// lanes rung asserts the live bucket is off), which differs from omitting the block (undeclared,
    /// not reconciled) - hence a separate signature instead of defaulted parameters.
    function addLane(
        string memory local,
        string memory remote,
        uint256 capacity,
        uint256 rate,
        uint256 inboundCapacity,
        uint256 inboundRate
    ) public {
        _addLane(
            local,
            remote,
            LanePolicy({
                capacity: capacity,
                rate: rate,
                withInbound: true,
                inboundCapacity: inboundCapacity,
                inboundRate: inboundRate
            })
        );
    }

    /// @dev The declared outbound (+ optional inbound) rate-limit policy of one new lane entry.
    struct LanePolicy {
        uint256 capacity;
        uint256 rate;
        bool withInbound;
        uint256 inboundCapacity;
        uint256 inboundRate;
    }

    function _addLane(string memory local, string memory remote, LanePolicy memory policy) internal {
        _requireSyncProfile();
        string memory localConfigPath = _requireConfigExists(local);
        string memory remoteConfigPath = _requireConfigExists(remote);
        require(
            keccak256(bytes(local)) != keccak256(bytes(remote)), "[add-lane] LOCAL and REMOTE must be different chains"
        );

        // Chain FACTS (chainSelector, chainFamily) come from config/chains; the lanes{} POLICY subtree
        // lives in the project store.
        string memory localConfig = vm.readFile(localConfigPath);
        string memory remoteConfig = vm.readFile(remoteConfigPath);
        _requireNotSelfLane(local, remote, localConfig, remoteConfig);
        require(
            keccak256(bytes(vm.parseJsonString(localConfig, ".chainFamily"))) == keccak256(bytes("evm")),
            string.concat("[add-lane] ", local, " is a non-EVM chain (destination-only) - it has no outbound lanes{}")
        );

        // Seed the project skeleton on first touch so the targeted `.lanes` write never raw-reverts.
        ProjectStore.seedIfAbsent(local);
        string memory projectPath = ProjectStore.path(local);
        string memory projectJson = vm.readFile(projectPath);
        if (vm.keyExistsJson(projectJson, string.concat(".lanes.", remote))) {
            string memory lanePath = string.concat(".lanes.", remote);
            if (_lanePolicyMatches(projectJson, lanePath, policy)) {
                // Identical re-run: a byte-identical no-op (the write is skipped entirely).
                console.log(
                    string.concat(
                        "[add-lane] lane ",
                        local,
                        " -> ",
                        remote,
                        " already exists - no-op (edit ",
                        ProjectStore.display(local),
                        " to change policy)"
                    )
                );
            } else {
                // Changed capacity/rate on an existing entry: never a silent no-op. WARN naming the
                // existing vs requested values, leave the entry unchanged, and name the remediation.
                _warnChangedLane(projectJson, lanePath, local, remote, policy);
            }
            return;
        }
        _warnPlaceholderPool(remote, remoteConfig);
        _writeLaneSubtree(
            local, projectPath, projectJson, remote, vm.parseJsonString(remoteConfig, ".chainSelector"), policy
        );
    }

    /// @dev The changed-args WARN: an existing entry with DIFFERENT capacity/rate, left unchanged.
    ///      Extracted from `_addLane` to keep its stack within the 16-slot limit.
    function _warnChangedLane(
        string memory json,
        string memory lanePath,
        string memory local,
        string memory remote,
        LanePolicy memory policy
    ) internal pure {
        console.log(
            string.concat(
                "[add-lane] WARN: lane ",
                local,
                " -> ",
                remote,
                " already exists with DIFFERENT policy (existing capacity=",
                vm.parseJsonString(json, string.concat(lanePath, ".capacity")),
                " rate=",
                vm.parseJsonString(json, string.concat(lanePath, ".rate")),
                ", requested capacity=",
                vm.toString(policy.capacity),
                " rate=",
                vm.toString(policy.rate),
                ") - left UNCHANGED. To change it, run make remove-lane LOCAL=",
                local,
                " REMOTE=",
                remote,
                " then re-run add-lane, or hand-edit config/chains/",
                local,
                ".json"
            )
        );
    }

    /// @dev Whether the existing lane entry at `lanePath` carries the SAME policy the caller passed
    ///      (capacity/rate, and the inbound{} block's presence + values). Governs the identical-re-run
    ///      no-op vs the changed-args WARN: an exact match is the idempotent no-op; any
    ///      difference is a footgun the WARN surfaces instead of silently ignoring.
    function _lanePolicyMatches(string memory json, string memory lanePath, LanePolicy memory policy)
        internal
        view
        returns (bool)
    {
        if (
            keccak256(bytes(vm.parseJsonString(json, string.concat(lanePath, ".capacity"))))
                != keccak256(bytes(vm.toString(policy.capacity)))
        ) return false;
        if (
            keccak256(bytes(vm.parseJsonString(json, string.concat(lanePath, ".rate"))))
                != keccak256(bytes(vm.toString(policy.rate)))
        ) return false;
        bool hasInbound = vm.keyExistsJson(json, string.concat(lanePath, ".inbound"));
        if (hasInbound != policy.withInbound) return false;
        if (policy.withInbound) {
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(lanePath, ".inbound.capacity"))))
                    != keccak256(bytes(vm.toString(policy.inboundCapacity)))
            ) return false;
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(lanePath, ".inbound.rate"))))
                    != keccak256(bytes(vm.toString(policy.inboundRate)))
            ) return false;
        }
        return true;
    }

    /// @dev Same-name is not the only self-lane: two config files can carry the SAME chainSelector. A
    /// lane whose remote selector equals the local selector would make the pool register ITSELF as a
    /// remote.
    function _requireNotSelfLane(
        string memory local,
        string memory remote,
        string memory json,
        string memory remoteJson
    ) internal pure {
        string memory localSelector = vm.parseJsonString(json, ".chainSelector");
        require(
            keccak256(bytes(localSelector)) != keccak256(bytes(vm.parseJsonString(remoteJson, ".chainSelector"))),
            string.concat(
                "[add-lane] ",
                local,
                " and ",
                remote,
                " share chainSelector ",
                localSelector,
                " - same chain under two names; refusing a self-lane"
            )
        );
    }

    /// @dev Preserve-and-replace the .lanes subtree: re-serialize every existing entry verbatim
    /// (including nested optional blocks - `inbound{}`, `v2{}` - via the recursive copier), then add
    /// the new entry and write the subtree back in one targeted `vm.writeJson`.
    function _writeLaneSubtree(
        string memory local,
        string memory projectPath,
        string memory json,
        string memory remote,
        string memory remoteSelector,
        LanePolicy memory policy
    ) internal {
        // Build the new entry with keys in SORTED order (capacity < inbound < rate < remoteSelector) so
        // forge's insertion-order writeJson is canonical.
        string memory newEntry = string.concat("lane-new-", remote);
        vm.serializeString(newEntry, "capacity", vm.toString(policy.capacity));
        if (policy.withInbound) {
            string memory inboundObj = string.concat("lane-new-inbound-", remote);
            vm.serializeString(inboundObj, "capacity", vm.toString(policy.inboundCapacity));
            vm.serializeString(
                newEntry, "inbound", vm.serializeString(inboundObj, "rate", vm.toString(policy.inboundRate))
            );
        }
        vm.serializeString(newEntry, "rate", vm.toString(policy.rate));
        string memory newEntryJson = vm.serializeString(newEntry, "remoteSelector", remoteSelector);

        // Merge existing + new lane names, sort them, then serialize in sorted order so the lanes{}
        // subtree stays byte-canonical (== jq -S) on the direct forge path.
        string[] memory existing = vm.parseJsonKeys(json, ".lanes");
        string[] memory names = new string[](existing.length + 1);
        for (uint256 i = 0; i < existing.length; i++) {
            names[i] = existing[i];
        }
        names[existing.length] = remote;
        names = _sortStrings(names);

        string memory lanesObj = string.concat("lanes-", local);
        string memory lanesJson = "{}";
        for (uint256 i = 0; i < names.length; i++) {
            string memory entry =
                keccak256(bytes(names[i])) == keccak256(bytes(remote)) ? newEntryJson : _copyLaneEntry(json, names[i]);
            lanesJson = vm.serializeString(lanesObj, names[i], entry);
        }

        vm.writeJson(lanesJson, projectPath, ".lanes");
        console.log(
            string.concat(
                "[add-lane] wrote lane ",
                local,
                " -> ",
                remote,
                " remoteSelector=",
                remoteSelector,
                " capacity=",
                vm.toString(policy.capacity),
                " rate=",
                vm.toString(policy.rate),
                policy.withInbound
                    ? string.concat(
                        " inboundCapacity=",
                        vm.toString(policy.inboundCapacity),
                        " inboundRate=",
                        vm.toString(policy.inboundRate)
                    )
                    : ""
            )
        );
        // Name the on-chain follow-up (mirrors remove-lane): the declaration is written, the pool is
        // untouched. Apply the policy on-chain, then verify with the doctor.
        console.log(
            string.concat(
                "[add-lane] declaration written; the pool is untouched - apply it on-chain via ApplyChainUpdates (script/setup/ApplyChainUpdates.s.sol) and verify with make doctor CHAIN=",
                local
            )
        );
    }

    /// @dev Re-serialize one existing lane entry verbatim, so the preserve-and-replace write cannot
    /// reshape entries it does not own. Recursive: leaf values are quoted-decimal strings per the
    /// schema, and nested objects (the optional `inbound{}` / `v2{}` policy blocks) are copied
    /// subtree-by-subtree.
    function _copyLaneEntry(string memory json, string memory laneName) internal returns (string memory) {
        return _copyJsonObject(json, string.concat(".lanes.", laneName));
    }

    /// @dev Copies the JSON object at `path` (all leaves are strings per the schema) into a fresh
    /// serialized object, recursing into nested objects. `parseJsonKeys` reverts on a non-object
    /// value, which is the leaf detector (cheatcode calls are external, so try/catch applies).
    function _copyJsonObject(string memory json, string memory path) internal returns (string memory) {
        string[] memory keys = vm.parseJsonKeys(json, path);
        if (keys.length == 0) return "{}";
        string memory obj = string.concat("copy-", path);
        string memory out = "{}";
        for (uint256 k = 0; k < keys.length; k++) {
            string memory childPath = string.concat(path, ".", keys[k]);
            try vm.parseJsonKeys(json, childPath) returns (string[] memory) {
                out = vm.serializeString(obj, keys[k], _copyJsonObject(json, childPath));
            } catch {
                out = vm.serializeString(obj, keys[k], vm.parseJsonString(json, childPath));
            }
        }
        return out;
    }

    /// @dev Byte-lexicographic insertion sort (matches `jq -S` key ordering for the ASCII lane keys),
    /// so the written `lanes{}` subtree is byte-canonical on the direct forge path.
    function _sortStrings(string[] memory a) internal pure returns (string[] memory) {
        for (uint256 i = 1; i < a.length; i++) {
            string memory k = a[i];
            uint256 j = i;
            while (j > 0 && _strLess(k, a[j - 1])) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = k;
        }
        return a;
    }

    function _strLess(string memory x, string memory y) private pure returns (bool) {
        bytes memory bx = bytes(x);
        bytes memory by = bytes(y);
        uint256 n = bx.length < by.length ? bx.length : by.length;
        for (uint256 i = 0; i < n; i++) {
            if (bx[i] != by[i]) return uint8(bx[i]) < uint8(by[i]);
        }
        return bx.length < by.length;
    }

    /// @dev WARN (not fail) when the remote chain has no `tokenPool` in its project store
    /// (`project/<remote>.json` `addresses.active.tokenPool`) — the lane can be declared ahead of the
    /// deploy, but the transfer scripts cannot execute against it until the pool exists. Also covers
    /// non-EVM remotes: the store holds their base58 pool (via `adopt-token`'s non-EVM path), so a
    /// Solana remote with a declared pool does not trip this WARN.
    function _warnPlaceholderPool(string memory remote, string memory) internal view {
        if (bytes(RegistryWriter.readString(remote, "tokenPool")).length == 0) {
            console.log(
                string.concat(
                    "[add-lane] WARN: no tokenPool in ",
                    ProjectStore.display(remote),
                    " (addresses.active.tokenPool) - deploy one (script/deploy/DeployBurnMintTokenPool.s.sol or DeployLockReleaseTokenPool.s.sol), or for a non-EVM remote declare it (make adopt-token), before executing transfers over this lane"
                )
            );
        }
    }

    // ================================================================
    // removeLane — `make remove-lane`: remove a lanes{} policy entry
    // ================================================================

    /// @notice Remove the `.lanes.<remote>` entry from the LOCAL chain's project store - the undo of
    /// `addLane`, with the same preserve-and-replace discipline: every OTHER lane entry is
    /// re-serialized verbatim (including nested `inbound{}`/`v2{}` blocks, via the recursive
    /// copier) and the subtree is written back in one targeted `vm.writeJson(json, path, ".lanes")`,
    /// so entries the write does not own survive intact. Removing a lane that is NOT declared is a
    /// logged no-op that leaves the file byte-identical (the same idempotence a duplicate `addLane`
    /// has). No API fetch, and no check that the remote's config file still exists: removing a
    /// dangling lane (the mesh rung's FAIL for a renamed or deleted remote) is exactly this
    /// command's job.
    /// @dev Declaration-only by design: the write touches `project/<local>.json` and never the pool.
    /// A lane that is applied on-chain must be removed there separately - the pool's
    /// `applyChainUpdates` takes the selector in its `remoteChainSelectorsToRemove` input (see
    /// `script/setup/ApplyChainUpdates.s.sol`) - and until it is, `make doctor`'s lanes rung WARNs
    /// that the on-chain lane is not declared in `lanes{}`. Removing the only lane leaves an empty
    /// `lanes{}`; a never-touched chain has no project file, so there is nothing to remove.
    function removeLane(string memory local, string memory remote) public {
        _requireSyncProfile();
        _requireConfigExists(local); // the chain must be onboarded
        string memory projectPath = ProjectStore.path(local);
        string memory lanePath = string.concat(".lanes.", remote);
        if (!vm.exists(projectPath) || !vm.keyExistsJson(vm.readFile(projectPath), lanePath)) {
            console.log(
                string.concat(
                    "[remove-lane] lane ",
                    local,
                    " -> ",
                    remote,
                    " is not declared - no-op (",
                    ProjectStore.display(local),
                    " unchanged)"
                )
            );
            return;
        }

        string memory json = vm.readFile(projectPath);
        string[] memory laneNames = vm.parseJsonKeys(json, ".lanes");
        string memory lanesObj = string.concat("lanes-rm-", local);
        string memory lanesJson = "{}";
        for (uint256 i = 0; i < laneNames.length; i++) {
            if (keccak256(bytes(laneNames[i])) == keccak256(bytes(remote))) continue;
            lanesJson = vm.serializeString(lanesObj, laneNames[i], _copyLaneEntry(json, laneNames[i]));
        }
        vm.writeJson(lanesJson, projectPath, ".lanes");
        console.log(
            string.concat("[remove-lane] removed lane ", local, " -> ", remote, " from ", ProjectStore.display(local))
        );
        console.log(
            string.concat(
                "[remove-lane] declaration removed; the pool is untouched - if the lane is applied on-chain, make doctor CHAIN=",
                local,
                " will WARN 'on-chain lane ... not declared in lanes{}' until it is removed on-chain via ApplyChainUpdates (the pool's applyChainUpdates 'remoteChainSelectorsToRemove' input)"
            )
        );
    }
}
