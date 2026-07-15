// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {LanePolicySource} from "../../utils/LanePolicySource.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {ProjectStore} from "../../../src/utils/ProjectStore.sol";

/// @notice Applies CCV (Cross-Chain Verifier) configuration to a token pool's AdvancedPoolHooks: the
///         four per-lane verifier arrays and/or the pool-global additional-CCV threshold.
///
/// @dev CCVs live on the pool's `AdvancedPoolHooks` contract, a v2.0-only surface
///      (`TokenPool.getAdvancedPoolHooks()`) that may be unset. This script:
///        - FENCES on the pool contract version (`applyCCVConfigUpdates` / `setThresholdAmount` are
///          2.0.0-only; a pre-2.0.0 pool is refused by name), then refuses by name when no hooks are wired;
///        - resolves each array (and the threshold) through the env > declared `lanes{}` > current
///          on-chain ladder shared with the fee/rate-limit scripts;
///        - is READ-MODIFY-WRITE: `applyCCVConfigUpdates` FULLY REPLACES a lane's entry, so the current
///          on-chain config is read first and every array the caller did NOT declare is carried through
///          unchanged (declaring only `OUTBOUND_CCVS` leaves the other three arrays at their live values);
///        - pre-checks the on-chain semantic rules with NAMED requires (a `threshold*CCVs` list requires a
///          non-empty base list; no duplicates within a list or shared between a list and its threshold
///          list) so the operator gets a clear message, not a raw revert.
///
/// The hooks contract is Ownable with its OWN owner (which may differ from the pool owner); this script
/// resolves and displays it and MUST be broadcast from that account.
///
/// Environment Variables:
///   DEST_CHAIN                 - the remote lane to configure CCVs for (optional; omit for threshold-only)
///   OUTBOUND_CCVS              - comma-separated address list: base CCVs for outbound messages
///   THRESHOLD_OUTBOUND_CCVS    - comma-separated address list: extra outbound CCVs at/above the threshold
///   INBOUND_CCVS               - comma-separated address list: base CCVs for inbound messages
///   THRESHOLD_INBOUND_CCVS     - comma-separated address list: extra inbound CCVs at/above the threshold
///   CCV_THRESHOLD_AMOUNT       - uint: the pool-global additional-CCV threshold amount (wei)
///
/// Ladder (PER ARRAY and for the threshold): env var > declared `lanes.<remote>.v2.ccv.<field>` /
/// chain-level `ccvThreshold` > the current on-chain value. An env value present (even empty, `=""`)
/// wins; an env value that diverges (as a SET, order-insensitive) from the declaration
/// prints a one-line notice and a closing hand-edit hint, and `make doctor` WARNs until reconciled
/// (`v2.ccv` has no add-lane flag — reconcile by a reviewed hand edit). lanes{} is owner intent: an
/// env-driven apply never writes it back.
///
/// Usage example (apply the declared lanes{} CCV policy — no CCV env vars):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/ccv/UpdateCCVConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (incident override for one direction):
///   DEST_CHAIN=MANTLE_SEPOLIA OUTBOUND_CCVS=0xCCV1,0xCCV2 \
///   forge script script/configure/ccv/UpdateCCVConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (threshold-only):
///   CCV_THRESHOLD_AMOUNT=1000000000000000000000 \
///   forge script script/configure/ccv/UpdateCCVConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateCCVConfig is EoaExecutor, LanePolicySource {
    HelperConfig public helperConfig;

    uint256 internal constant NUM_CCV_FIELDS = 4;

    /// @dev How one CCV array was resolved through the per-array input ladder.
    struct CcvFieldResolution {
        bool fromEnv; // rung 1: the env var is set
        bool fromLanes; // rung 2: no env var, declared v2.ccv array used
        bool declared; // the array exists in the declared v2.ccv block
        address[] declaredValue;
        bool diverges; // env override differs (as a SET) from the declared value
        address[] value; // the resolved value that will be applied
    }

    /// @dev How the pool-global threshold was resolved (env > chain-level ccvThreshold > current).
    struct ThresholdResolution {
        bool fromEnv;
        bool fromLanes;
        bool declared; // chain-level ccvThreshold key exists
        uint256 declaredValue;
        bool diverges;
        uint256 value;
    }

    /// @dev The full CCV resolution plus everything the console (and the tests) need to explain it.
    struct CCVConfigResolution {
        CcvFieldResolution[NUM_CCV_FIELDS] fields; // outbound, thresholdOutbound, inbound, thresholdInbound
        ThresholdResolution threshold;
        bool configFound; // config/chains/<configName>.json exists for the local chain
        string configName;
        bool laneFound;
        string laneKey; // the matched entry, or the remote's config basename for hints
        bool blockDeclared; // lanes.<key>.v2.ccv exists
        bool anyArrayEnv;
        bool anyArrayFromLanes;
        bool anyArrayDeclared; // any array came from env OR a declared block (gates the lane write)
        bool anyDiverges; // any array OR the threshold diverges
        bool editHint; // an env-driven apply left the array declaration missing or diverging
        bool thresholdHint; // an env-driven threshold apply left the declaration missing or diverging
        string[NUM_CCV_FIELDS] fieldNotices; // per-array divergence notice (empty unless that array diverges)
        string thresholdNotice; // threshold divergence notice (empty unless it diverges)
        string editHintText; // composed closing hand-edit hint for the arrays (empty unless editHint)
        string thresholdHintText; // composed closing hand-edit hint for the threshold (empty unless thresholdHint)
    }

    function run() external {
        string memory destChainName = vm.envOr("DEST_CHAIN", string(""));
        bool haveLane = bytes(destChainName).length > 0;

        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // ── Version fence + hooks resolution (both refuse by name) ─────────
        address hooksAddress = _fencedHooks(tokenPoolAddress, haveLane);
        address hooksOwner = AdvancedPoolHooks(hooksAddress).owner();

        _header(chainName, tokenPoolAddress, hooksAddress, hooksOwner, destChainName, haveLane);

        // ── Read current on-chain state (RMW baseline) ─────────────────────
        uint64 destChainSelector = haveLane
            ? helperConfig.getNetworkConfig(helperConfig.parseChainName(destChainName)).chainSelector
            : uint64(0);
        AdvancedPoolHooks.CCVConfig memory currentConfig =
            haveLane ? AdvancedPoolHooks(hooksAddress).getCCVConfig(destChainSelector) : _emptyConfig();
        uint256 currentThreshold = AdvancedPoolHooks(hooksAddress).getThresholdAmount();

        CCVConfigResolution memory res =
            _resolveCCVConfig(currentConfig, currentThreshold, destChainName, destChainSelector);
        _logResolution(res, haveLane);

        // ── Build the calls (lane arrays + / or the global threshold) ──────
        CctActions.Call[] memory calls = new CctActions.Call[](0);
        if (haveLane && res.anyArrayDeclared) {
            // The hooks contract REMOVES a lane from its configured set when both the outbound and
            // inbound base arrays are empty (AdvancedPoolHooks.applyCCVConfigUpdates). Surface that so
            // an all-empty apply is never a silent removal of the lane's CCV requirement.
            if (res.fields[0].value.length == 0 && res.fields[2].value.length == 0) {
                console.log(
                    string.concat(
                        unicode"⚠️  Both outboundCCVs and inboundCCVs resolve empty for ",
                        destChainName,
                        " - this REMOVES the lane's CCV requirement from the hooks contract (the lane is dropped from the configured set)."
                    )
                );
            }
            AdvancedPoolHooks.CCVConfigArg[] memory args = _buildCCVArgs(res, destChainSelector);
            calls = CctActions.applyCCVConfigUpdates(hooksAddress, args);
        }
        bool writeThreshold =
            (res.threshold.fromEnv || res.threshold.fromLanes) && res.threshold.value != currentThreshold;
        if (writeThreshold) {
            console.log(
                string.concat(
                    "[threshold] Setting pool-global additional-CCV threshold to ", vm.toString(res.threshold.value)
                )
            );
            calls = CctActions.concat(calls, CctActions.setThresholdAmount(hooksAddress, res.threshold.value));
        }

        if (calls.length == 0) {
            console.log(
                unicode"ℹ️  Nothing to apply: no CCV arrays or threshold declared (env or lanes{}) for this run."
            );
            _footer(chainId, tokenPoolAddress, res);
            return;
        }

        console.log(
            unicode"⚠️  CCVs gate message verification: a wrong or unreachable verifier set can block a lane's messages - verify the addresses before broadcasting."
        );
        console.log(
            string.concat(
                "[apply] Broadcasting ",
                vm.toString(calls.length),
                " call(s) as the hooks owner ",
                vm.toString(hooksOwner)
            )
        );
        executeCalls(calls);
        console.log(unicode"✅ CCV config applied successfully!");

        _footer(chainId, tokenPoolAddress, res);
    }

    // ── Version fence + hooks resolution ────────────────────────────────────

    /// @dev Fences on the pool contract version (applyCCVConfigUpdates / setThresholdAmount are
    ///      2.0.0-only, refused by name via requireSupports) and then refuses by name when no
    ///      AdvancedPoolHooks is wired. Returns the resolved hooks address. This script broadcasts, so
    ///      it uses `resolve` (which refuses uncataloged/-dev pools) rather than the degrading path.
    function _fencedHooks(address pool, bool haveLane) internal view returns (address hooksAddress) {
        (PoolVersions.Version poolVersion,) = PoolVersion.resolve(pool);
        PoolVersions.requireSupports(
            haveLane ? PoolVersions.Op.APPLY_CCV_CONFIG : PoolVersions.Op.SET_CCV_THRESHOLD, poolVersion, pool
        );
        hooksAddress = address(TokenPool(pool).getAdvancedPoolHooks());
        require(
            hooksAddress != address(0),
            string.concat(
                "No AdvancedPoolHooks wired to pool ",
                vm.toString(pool),
                " - CCV config lives on the hooks contract. Deploy one (script/configure/allowlist/DeployAdvancedPoolHooks.s.sol) and wire it (script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol, NEW_HOOK=<addr>) before configuring CCVs."
            )
        );
    }

    // ── Header / footer ────────────────────────────────────────────────────

    function _header(
        string memory chainName,
        address pool,
        address hooks,
        address hooksOwner,
        string memory destChainName,
        bool haveLane
    ) private pure {
        console.log("");
        console.log("========================================");
        console.log(unicode"🛡️  Update CCV Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Remote Chain: ", haveLane ? destChainName : "(threshold-only, no lane)"));
        console.log(string.concat("Token Pool:   ", vm.toString(pool)));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooks)));
        console.log(string.concat("Hooks Owner:  ", vm.toString(hooksOwner)));
        console.log("   (broadcast this run from the hooks owner account)");
        console.log("========================================");
        console.log("");
    }

    function _footer(uint256 chainId, address pool, CCVConfigResolution memory res) private view {
        console.log("");
        console.log("========================================");
        console.log(unicode"✅ Operation Complete!");
        console.log("========================================");
        console.log(string.concat("Token Pool: ", helperConfig.getExplorerUrl(chainId, "/address/", pool)));
        console.log("========================================");
        if (res.editHint) console.log(res.editHintText);
        if (res.thresholdHint) console.log(res.thresholdHintText);
        console.log("");
    }

    // ── Input resolution (per array + threshold: env > lanes{} > current) ───

    function _ccvEnvNames() internal pure returns (string[NUM_CCV_FIELDS] memory) {
        return [string("OUTBOUND_CCVS"), "THRESHOLD_OUTBOUND_CCVS", "INBOUND_CCVS", "THRESHOLD_INBOUND_CCVS"];
    }

    function _ccvFieldNames() internal pure returns (string[NUM_CCV_FIELDS] memory) {
        return [string("outboundCCVs"), "thresholdOutboundCCVs", "inboundCCVs", "thresholdInboundCCVs"];
    }

    /// @dev Resolves the four CCV arrays and the pool-global threshold through the per-field ladder:
    ///      env > declared `v2.ccv.<field>` / chain-level `ccvThreshold` > current on-chain value.
    ///      An UNDECLARED array carries the current on-chain value (the read-modify-write invariant:
    ///      applyCCVConfigUpdates fully replaces the entry). lanes{} is OWNER INTENT — an env-driven
    ///      apply never writes it back.
    function _resolveCCVConfig(
        AdvancedPoolHooks.CCVConfig memory currentConfig,
        uint256 currentThreshold,
        string memory destChainName,
        uint64 destChainSelector
    ) internal view returns (CCVConfigResolution memory res) {
        address[][NUM_CCV_FIELDS] memory currentValues = [
            currentConfig.outboundCCVs,
            currentConfig.thresholdOutboundCCVs,
            currentConfig.inboundCCVs,
            currentConfig.thresholdInboundCCVs
        ];
        string[NUM_CCV_FIELDS] memory envNames = _ccvEnvNames();
        string[NUM_CCV_FIELDS] memory fieldNames = _ccvFieldNames();

        // lanes{} (per-lane v2.ccv) from the project store; ccvThreshold (chain-level) from config.
        string memory configJson;
        (res.configFound, res.configName, configJson) = _findLocalChainConfig();
        string memory json = _localProjectJson(res.configName);
        if (res.configFound && bytes(destChainName).length > 0) {
            (res.laneFound, res.laneKey) = _findLaneKey(json, destChainName, destChainSelector);
        }
        if (!res.laneFound && bytes(destChainName).length > 0) res.laneKey = _remoteConfigName(destChainName);
        string memory blockPath = string.concat(".lanes.", res.laneKey, ".v2.ccv");
        res.blockDeclared = res.laneFound && vm.keyExistsJson(json, blockPath);

        for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
            _resolveArray(res, json, blockPath, envNames[i], fieldNames[i], currentValues[i], i);
        }
        _resolveThreshold(res, configJson, currentThreshold);

        res.editHint = res.anyArrayEnv && res.configFound && (!res.blockDeclared || _anyArrayDiverges(res));

        for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
            if (res.fields[i].diverges) res.fieldNotices[i] = _composeCcvNotice(res, i);
        }
        if (res.threshold.diverges) res.thresholdNotice = _composeThresholdNotice(res);
        if (res.editHint) res.editHintText = _composeCcvEditHint(res);
        if (res.thresholdHint) res.thresholdHintText = _composeThresholdEditHint(res);
    }

    function _resolveArray(
        CCVConfigResolution memory res,
        string memory json,
        string memory blockPath,
        string memory envName,
        string memory fieldName,
        address[] memory current,
        uint256 i
    ) private view {
        CcvFieldResolution memory f = res.fields[i];
        f.fromEnv = _envExists(envName);
        if (res.blockDeclared) {
            string memory fieldKey = string.concat(blockPath, ".", fieldName);
            f.declared = vm.keyExistsJson(json, fieldKey);
            if (f.declared) f.declaredValue = vm.parseJsonAddressArray(json, fieldKey);
        }
        if (f.fromEnv) {
            f.value = HelperUtils.parseAddressArray(vm, _envString(envName), "");
            f.diverges = f.declared && !_sameAddressSet(f.value, f.declaredValue);
        } else if (f.declared) {
            f.fromLanes = true;
            f.value = f.declaredValue;
        } else {
            f.value = current; // rung 3: RMW — carry the current on-chain value
        }
        res.anyArrayEnv = res.anyArrayEnv || f.fromEnv;
        res.anyArrayFromLanes = res.anyArrayFromLanes || f.fromLanes;
        res.anyArrayDeclared = res.anyArrayDeclared || f.fromEnv || f.declared;
        res.anyDiverges = res.anyDiverges || f.diverges;
    }

    function _resolveThreshold(CCVConfigResolution memory res, string memory json, uint256 currentThreshold)
        private
        view
    {
        ThresholdResolution memory t = res.threshold;
        t.fromEnv = _envExists("CCV_THRESHOLD_AMOUNT");
        t.declared = res.configFound && vm.keyExistsJson(json, ".ccvThreshold");
        if (t.declared) t.declaredValue = vm.parseJsonUint(json, ".ccvThreshold");
        if (t.fromEnv) {
            t.value = _envUint("CCV_THRESHOLD_AMOUNT");
            t.diverges = t.declared && t.value != t.declaredValue;
        } else if (t.declared) {
            t.fromLanes = true;
            t.value = t.declaredValue;
        } else {
            t.value = currentThreshold;
        }
        res.anyDiverges = res.anyDiverges || t.diverges;
        res.thresholdHint = t.fromEnv && res.configFound && (!t.declared || t.diverges);
    }

    function _anyArrayDiverges(CCVConfigResolution memory res) private pure returns (bool) {
        for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
            if (res.fields[i].diverges) return true;
        }
        return false;
    }

    // ── Console logging ─────────────────────────────────────────────────────

    function _logResolution(CCVConfigResolution memory res, bool haveLane) private view {
        if (res.anyArrayFromLanes) {
            console.log(
                string.concat(
                    "CCV arrays resolved from lanes.",
                    res.laneKey,
                    ".v2.ccv in ",
                    ProjectStore.display(res.configName),
                    " (undeclared arrays keep the current on-chain values)"
                )
            );
        }
        if (res.threshold.fromLanes) {
            console.log(
                string.concat(
                    "CCV threshold resolved from chain-level ccvThreshold in config/chains/", res.configName, ".json"
                )
            );
        }
        string[NUM_CCV_FIELDS] memory fieldNames = _ccvFieldNames();
        if (haveLane) {
            for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
                console.log(
                    string.concat(
                        "  ",
                        fieldNames[i],
                        " = ",
                        _addrArrayToString(res.fields[i].value),
                        " ",
                        _sourceLabel(res.fields[i])
                    )
                );
            }
        }
        console.log(string.concat("  ccvThreshold = ", vm.toString(res.threshold.value)));
        for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
            if (res.fields[i].diverges) console.log(res.fieldNotices[i]);
        }
        if (res.threshold.diverges) console.log(res.thresholdNotice);
        console.log("");
    }

    /// @dev Labels which rung a resolved array came from, so the operator sees which arrays are being
    ///      changed (env / lanes{}) vs preserved (current on-chain, carried through by the RMW read).
    function _sourceLabel(CcvFieldResolution memory f) private pure returns (string memory) {
        if (f.fromEnv) return "(source: env)";
        if (f.fromLanes) return "(source: lanes{})";
        return "(source: current on-chain, carried through)";
    }

    // ── Notice / hint composition (byte-exact, pinned in tests) ────────────

    function _composeCcvNotice(CCVConfigResolution memory res, uint256 i) private view returns (string memory) {
        return string.concat(
            unicode"⚠️  ",
            _ccvEnvNames()[i],
            "=",
            _addrArrayToString(res.fields[i].value),
            " diverges from declared lanes.",
            res.laneKey,
            ".v2.ccv.",
            _ccvFieldNames()[i],
            "=",
            _addrArrayToString(res.fields[i].declaredValue),
            " in ",
            ProjectStore.display(res.configName),
            " - make doctor will WARN until reconciled"
        );
    }

    function _composeThresholdNotice(CCVConfigResolution memory res) private pure returns (string memory) {
        return string.concat(
            unicode"⚠️  CCV_THRESHOLD_AMOUNT=",
            vm.toString(res.threshold.value),
            " diverges from declared ccvThreshold=",
            vm.toString(res.threshold.declaredValue),
            " in config/chains/",
            res.configName,
            ".json - make doctor will WARN until reconciled"
        );
    }

    function _composeCcvEditHint(CCVConfigResolution memory res) private view returns (string memory) {
        string[NUM_CCV_FIELDS] memory fieldNames = _ccvFieldNames();
        string memory values = "";
        for (uint256 i = 0; i < NUM_CCV_FIELDS; i++) {
            values =
                string.concat(values, i == 0 ? "" : " ", fieldNames[i], "=", _addrArrayToString(res.fields[i].value));
        }
        return string.concat(
            unicode"⚠️  Applied CCV config is ",
            res.blockDeclared ? "diverging from" : "not declared in",
            " lanes.",
            res.laneKey,
            ".v2.ccv (",
            ProjectStore.display(res.configName),
            "). Hand-edit the block to the applied values: ",
            values,
            " - make doctor CHAIN=",
            res.configName,
            " WARNs until reconciled"
        );
    }

    function _composeThresholdEditHint(CCVConfigResolution memory res) private pure returns (string memory) {
        return string.concat(
            unicode"⚠️  Applied CCV threshold ",
            vm.toString(res.threshold.value),
            res.threshold.declared ? " is diverging from" : " is not declared as",
            " ccvThreshold in config/chains/",
            res.configName,
            ".json - make doctor CHAIN=",
            res.configName,
            " WARNs until reconciled"
        );
    }

    // ── Call building + semantic pre-checks (named requires) ────────────────

    /// @dev Builds the single-lane CCVConfigArg from the resolved arrays, after enforcing the on-chain
    ///      semantic rules by name (so the operator gets a clear message, not a raw revert): a
    ///      threshold list requires a non-empty base list in the same direction; no address may appear
    ///      twice within a list or be shared between a list and its threshold list.
    function _buildCCVArgs(CCVConfigResolution memory res, uint64 destChainSelector)
        internal
        pure
        returns (AdvancedPoolHooks.CCVConfigArg[] memory args)
    {
        address[] memory outbound = res.fields[0].value;
        address[] memory thresholdOutbound = res.fields[1].value;
        address[] memory inbound = res.fields[2].value;
        address[] memory thresholdInbound = res.fields[3].value;

        _requireNoDuplicates("outboundCCVs", outbound);
        _requireNoDuplicates("thresholdOutboundCCVs", thresholdOutbound);
        _requireNoDuplicates("inboundCCVs", inbound);
        _requireNoDuplicates("thresholdInboundCCVs", thresholdInbound);
        _requireThresholdHasBase("outbound", thresholdOutbound, outbound);
        _requireThresholdHasBase("inbound", thresholdInbound, inbound);
        _requireNotShared("outbound", outbound, thresholdOutbound);
        _requireNotShared("inbound", inbound, thresholdInbound);

        args = new AdvancedPoolHooks.CCVConfigArg[](1);
        args[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: destChainSelector,
            outboundCCVs: outbound,
            thresholdOutboundCCVs: thresholdOutbound,
            inboundCCVs: inbound,
            thresholdInboundCCVs: thresholdInbound
        });
    }

    function _requireNoDuplicates(string memory field, address[] memory arr) private pure {
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = i + 1; j < arr.length; j++) {
                require(
                    arr[i] != arr[j],
                    string.concat(
                        "CCV field ",
                        field,
                        " contains a duplicate address ",
                        vm.toString(arr[i]),
                        "; remove the duplicate (the hooks contract rejects duplicates)"
                    )
                );
            }
        }
    }

    function _requireThresholdHasBase(string memory dir, address[] memory threshold, address[] memory base)
        private
        pure
    {
        require(
            threshold.length == 0 || base.length > 0,
            string.concat(
                "CCV ",
                dir,
                " threshold list is non-empty but the base ",
                dir,
                "CCVs list is empty; a threshold list requires a non-empty base list (specify address(0) to use the defaults below the threshold)"
            )
        );
    }

    function _requireNotShared(string memory dir, address[] memory base, address[] memory threshold) private pure {
        for (uint256 i = 0; i < base.length; i++) {
            for (uint256 j = 0; j < threshold.length; j++) {
                require(
                    base[i] != threshold[j],
                    string.concat(
                        "CCV ",
                        dir,
                        " address ",
                        vm.toString(base[i]),
                        " appears in both the base and the threshold list; an address must not be shared between a list and its threshold list"
                    )
                );
            }
        }
    }

    // ── Address-array helpers ───────────────────────────────────────────────

    function _emptyConfig() private pure returns (AdvancedPoolHooks.CCVConfig memory) {
        return AdvancedPoolHooks.CCVConfig({
            outboundCCVs: new address[](0),
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: new address[](0),
            thresholdInboundCCVs: new address[](0)
        });
    }

    /// @dev SET equality (order-insensitive) of two address arrays: equal length and mutual containment.
    ///      Used for divergence so a re-ordering of the same CCV set is not spurious drift.
    function _sameAddressSet(address[] memory a, address[] memory b) private pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (!_contains(b, a[i])) return false;
        }
        for (uint256 i = 0; i < b.length; i++) {
            if (!_contains(a, b[i])) return false;
        }
        return true;
    }

    function _contains(address[] memory arr, address x) private pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == x) return true;
        }
        return false;
    }

    /// @dev Compact "[0xA,0xB]" rendering for notices/hints (in the value's order).
    function _addrArrayToString(address[] memory arr) private pure returns (string memory out) {
        out = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            out = string.concat(out, i == 0 ? "" : ",", vm.toString(arr[i]));
        }
        out = string.concat(out, "]");
    }
}
