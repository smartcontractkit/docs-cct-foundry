// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {IConfigSource} from "../../src/config/IConfigSource.sol";
import {CcipApiSource} from "../../src/config/CcipApiSource.sol";

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
///
/// @dev What the sync OWNS (overwrites): every API-served field. That is the `ccip{}` object — the
/// API-syncable, directory-canonical addresses (`router`, `rmnProxy`, `tokenAdminRegistry`,
/// `registryModuleOwnerCustom`, `link`, `feeQuoter`, `tokenPoolFactory`, `feeTokens[]`) — AND the
/// API-served identity + metadata fields (`displayName`, `chainFamily`, `environment`, `explorerUrl`,
/// `nativeCurrencySymbol`), all of which `GET /v2/chains/{selector}` serves, so none is hand-typed.
/// What it PRESERVES (never touches): the genuinely hand-authored keys the API serves nothing for
/// (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`), and the immutable join keys
/// (`name`/`chainSelector`/`chainId`) which are GUARD-validated, not rewritten. One writer per field.
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
    function _source() internal returns (IConfigSource) {
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
    /// hand-typed. Hand-authored keys (`chainNameIdentifier`, `rpcEnv`, `confirmations`, `ccipBnM`)
    /// and the immutable join keys (`name`/`chainSelector`/`chainId`, guarded, not rewritten) are
    /// preserved untouched. Non-EVM chains have no EVM-shaped `chainConfig`, so their `ccip{}` block
    /// stays zeroed (SKIP), but their chain-level identity + metadata ARE served and get refreshed.
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
    /// `rpcEnv`, `confirmations`, `ccipBnM`.
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
    /// `explorerUrl`, `nativeCurrencySymbol`, `ccipBnM`) are written as review-me defaults.
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
        // Genuinely hand-authored (the API serves nothing for these): confirmations (block
        // confirmations the scripts wait for — user-overridable per chain, preserved by sync) and
        // ccipBnM (optional). explorerUrl/nativeCurrencySymbol are seeded empty here but the
        // `run(localName)` call below sources them from the API's chainMetadata in the same invocation.
        vm.serializeUint(root, "confirmations", 2);
        vm.serializeString(root, "explorerUrl", "");
        vm.serializeString(root, "nativeCurrencySymbol", "");
        vm.serializeAddress(root, "ccipBnM", address(0));
        // `vm.writeJson` cannot CREATE keys, so the stub must ship an (empty) ccip object.
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
        // (e.g. AVALANCHE_TESTNET_FUJI, not AVALANCHE_FUJI). Printing them removes the guesswork — the
        // operator no longer has to open the generated JSON to learn which env var to export.
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
                ".json: chainNameIdentifier, rpcEnv, confirmations, explorerUrl, nativeCurrencySymbol, ccipBnM"
            )
        );
        if (isEvm) {
            console.log(
                "  3. no Solidity change needed - HelperConfig discovers the chain from config/chains/ automatically"
            );
            console.log(
                string.concat(
                    "  4. verify: FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig \"run(string)\" ",
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
}
