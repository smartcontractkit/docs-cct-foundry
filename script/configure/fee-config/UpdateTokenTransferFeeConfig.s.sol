// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {LanePolicySource} from "../../utils/LanePolicySource.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Applies token transfer fee configuration updates to a token pool on a given destination lane.
///
/// @dev This function is only available on TokenPool v2.0 and later. Prior to v2.0, fee configuration
///      is managed by FeeQuoter and configured directly by the Chainlink team upon token issuer request.
///      If the pool does not support this function, the script will revert with an informative message.
///
/// To enable or update the fee config for a lane, provide the env vars below with DISABLE unset or false.
/// To disable the fee config (reverting to FeeQuoter defaults), set DISABLE=true.
///
/// Environment Variables (required):
///   DEST_CHAIN    - The remote destination chain to configure fees for (e.g. MANTLE_SEPOLIA)
///
/// Environment Variables (per-field, optional when DISABLE is false or unset — see the ladder below):
///   DEST_GAS_OVERHEAD             - uint32, gas overhead charged on destination chain (must be > 0)
///   DEST_BYTES_OVERHEAD           - uint32, data availability bytes overhead on destination chain
///   FINALITY_FEE_USD_CENTS        - uint32, fixed fee in 0.01 USD units for finality transfers
///   FAST_FINALITY_FEE_USD_CENTS   - uint32, fixed fee in 0.01 USD units for fast finality transfers
///   FINALITY_TRANSFER_FEE_BPS     - uint16, bps fee deducted from transferred amount for finality transfers [0-9999]
///   FAST_FINALITY_TRANSFER_FEE_BPS - uint16, bps fee deducted from transferred amount for fast finality transfers [0-9999]
///
/// Environment Variables (optional):
///   DISABLE  - true/false, set to true to disable the fee config for this lane (default: false)
///
/// Fee-config input resolution ladder (PER FIELD — the same env-over-lanes{} ladder
/// ApplyChainUpdates and UpdateRateLimiters use, extending the script's historical per-field env
/// semantics, where each unset env var independently fell back to the current on-chain value):
///   1. Env var set → the env value wins, byte-for-byte the historical behavior. When the local
///      chain config declares a diverging `lanes.<remote>.v2.feeConfig.<field>`, a one-line console
///      notice names both values (`make doctor` WARNs until reconciled) and the closing output
///      prints a hand-edit remediation hint.
///   2. Env var unset → the declared `v2.feeConfig.<field>` supplies the value when declared (with
///      no env vars at all, the whole config comes from the declared block). An undeclared field
///      falls through to rung 3 — the doctor's absent-means-undeclared rule.
///   3. Neither → the current on-chain value, exactly the historical default (zero when no config
///      is stored yet).
/// A partial env set therefore behaves exactly as before for the set fields, and each unset field
/// takes its declared value before the on-chain fallback. lanes{} is owner intent — an env-driven
/// apply never writes it back. `make add-lane` has no flag surface for the v2{} blocks (deliberate:
/// they are declared by a reviewed hand edit), so the closing hint is a hand-edit instruction; the
/// doctor WARN closes the loop.
///
/// Usage example (enable / update fee config):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   DEST_GAS_OVERHEAD=50000 \
///   DEST_BYTES_OVERHEAD=0 \
///   FINALITY_FEE_USD_CENTS=0 \
///   FAST_FINALITY_FEE_USD_CENTS=100 \
///   FINALITY_TRANSFER_FEE_BPS=0 \
///   FAST_FINALITY_TRANSFER_FEE_BPS=50 \
///   forge script script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (apply the declared lanes{} fee policy — no fee env vars):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
///
/// Usage example (disable fee config):
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   DISABLE=true \
///   forge script script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract UpdateTokenTransferFeeConfig is EoaExecutor, LanePolicySource {
    HelperConfig public helperConfig;

    uint256 internal constant NUM_FEE_FIELDS = 6;

    /// @dev How one fee-config field was resolved through the per-field input ladder.
    struct FeeFieldResolution {
        bool fromEnv; // rung 1: the env var is set
        bool fromLanes; // rung 2: no env var, declared v2.feeConfig field used
        bool declared; // the field exists in the declared v2.feeConfig block
        uint256 declaredValue;
        bool diverges; // env override differs from the declared value
        uint256 value; // the resolved value that will be applied
    }

    /// @dev The full fee-config resolution, plus everything the console (and the tests) need to
    ///      explain the decision: which lanes{} entry matched, whether the v2.feeConfig block is
    ///      declared, and the hand-edit remediation hint state.
    struct FeeConfigResolution {
        FeeFieldResolution[NUM_FEE_FIELDS] fields;
        bool configFound; // config/chains/<configName>.json exists for the local chain
        string configName;
        bool laneFound;
        string laneKey; // the matched entry, or the remote's config basename for hints
        bool blockDeclared; // lanes.<key>.v2.feeConfig exists
        bool anyEnv;
        bool anyFromLanes;
        bool anyDiverges;
        bool editHint; // an env-driven apply left the declaration missing or diverging
        string[NUM_FEE_FIELDS] fieldNotices; // per-field divergence notice (empty unless that field diverges)
        string editHintText; // composed closing hand-edit hint (empty unless editHint)
    }

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");
        bool disable = vm.envOr("DISABLE", false);

        // ── Resolve chain IDs, selectors ────────────────────────────────
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        uint256 destChainId = helperConfig.parseChainName(destChainName);
        uint64 destChainSelector = helperConfig.getNetworkConfig(destChainId).chainSelector;

        // ── Resolve pool address ───────────────────────────────────────────
        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );

        // ── Version fence ──────────────────────────────────────────────────
        // applyTokenTransferFeeConfigUpdates is a v2-only setter. Resolve the pool's on-chain
        // contract version and refuse by name on any version that does not carry it, BEFORE any
        // v2-surface read (getTokenTransferFeeConfig) or the write. This script broadcasts, so use
        // resolve (which refuses uncataloged/-dev pools rather than degrading).
        (PoolVersions.Version poolVersion,) = PoolVersion.resolve(tokenPoolAddress);
        PoolVersions.requireSupports(PoolVersions.Op.SET_TOKEN_TRANSFER_FEE_CONFIG, poolVersion, tokenPoolAddress);

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"💰 Update Token Transfer Fee Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", disable ? "Disable fee config" : "Set fee config"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Dest Chain Selector: ", vm.toString(destChainSelector)));
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        require(
            tokenPool.isSupportedChain(destChainSelector),
            string.concat(
                "Destination chain ",
                helperConfig.getChainName(destChainId),
                " (selector: ",
                vm.toString(destChainSelector),
                ") is not configured on this pool. Run ApplyChainUpdates first."
            )
        );

        FeeConfigResolution memory res;
        if (disable) {
            // ── Disable fee config for this lane ──────────────────────────
            console.log(
                string.concat("[Step 1] Disabling fee config for lane to ", helperConfig.getChainName(destChainId))
            );

            uint64[] memory toDisable = new uint64[](1);
            toDisable[0] = destChainSelector;
            TokenPool.TokenTransferFeeConfigArgs[] memory emptyArgs = new TokenPool.TokenTransferFeeConfigArgs[](0);

            // applyTokenTransferFeeConfigUpdates() was introduced in TokenPool v2.0.
            // On v1 pools, fee configuration is handled by FeeQuoter and requires
            // a direct request to the Chainlink team — it cannot be modified here.
            executeCalls(CctActions.applyTokenTransferFeeConfigUpdates(tokenPoolAddress, emptyArgs, toDisable));
            console.log(unicode"✅ Fee config disabled for this lane.");
            console.log("   The OnRamp will now use FeeQuoter defaults for this destination.");
        } else {
            // ── Read current on-chain config as defaults ───────────────────
            IPoolV2.TokenTransferFeeConfig memory currentConfig;
            try tokenPool.getTokenTransferFeeConfig(address(0), destChainSelector, 0, "") returns (
                IPoolV2.TokenTransferFeeConfig memory cfg
            ) {
                currentConfig = cfg;
                console.log("Current On-Chain Fee Configuration:");
                console.log(
                    string.concat("  isEnabled:                    ", currentConfig.isEnabled ? "true" : "false")
                );
                console.log(
                    string.concat("  destGasOverhead:              ", vm.toString(currentConfig.destGasOverhead))
                );
                console.log(
                    string.concat("  destBytesOverhead:            ", vm.toString(currentConfig.destBytesOverhead))
                );
                console.log(
                    string.concat("  finalityFeeUSDCents:          ", vm.toString(currentConfig.finalityFeeUSDCents))
                );
                console.log(
                    string.concat(
                        "  fastFinalityFeeUSDCents:      ", vm.toString(currentConfig.fastFinalityFeeUSDCents)
                    )
                );
                console.log(
                    string.concat("  finalityTransferFeeBps:       ", vm.toString(currentConfig.finalityTransferFeeBps))
                );
                console.log(
                    string.concat(
                        "  fastFinalityTransferFeeBps:   ", vm.toString(currentConfig.fastFinalityTransferFeeBps)
                    )
                );
                console.log("");
            } catch {
                // Pool is v1 or config not yet set — all defaults will be zero.
            }

            res = _resolveFeeConfig(currentConfig, destChainName, destChainSelector);
            _logFeeResolution(res);

            TokenPool.TokenTransferFeeConfigArgs[] memory args = _buildFeeConfigArgs(res, destChainSelector);
            uint64[] memory emptyDisable = new uint64[](0);

            console.log(
                string.concat("[Step 1] Applying fee config for lane to ", helperConfig.getChainName(destChainId))
            );

            // applyTokenTransferFeeConfigUpdates() was introduced in TokenPool v2.0.
            // On v1 pools, fee configuration is handled by FeeQuoter and requires
            // a direct request to the Chainlink team — it cannot be modified here.
            executeCalls(CctActions.applyTokenTransferFeeConfigUpdates(tokenPoolAddress, args, emptyDisable));
            console.log(unicode"✅ Fee config applied successfully!");
        }

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"✅ Operation Complete!");
        console.log("========================================");
        console.log(string.concat("Token Pool: ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Token Pool: ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress)));
        console.log("========================================");
        if (!disable) _logFeeEditHint(res);
        console.log("");
    }

    // ── Input resolution (per field: env > lanes{} > current on-chain) ─────

    /// @dev The six env var names, in the fixed field order the resolution uses everywhere.
    function _feeEnvNames() internal pure returns (string[NUM_FEE_FIELDS] memory) {
        return [
            string("DEST_GAS_OVERHEAD"),
            "DEST_BYTES_OVERHEAD",
            "FINALITY_FEE_USD_CENTS",
            "FAST_FINALITY_FEE_USD_CENTS",
            "FINALITY_TRANSFER_FEE_BPS",
            "FAST_FINALITY_TRANSFER_FEE_BPS"
        ];
    }

    /// @dev The six declared v2.feeConfig field names, in the same order — exactly the fields the
    ///      doctor reconciles (`VerifyChain._reconcileFeeConfig`).
    function _feeFieldNames() internal pure returns (string[NUM_FEE_FIELDS] memory) {
        return [
            string("destGasOverhead"),
            "destBytesOverhead",
            "finalityFeeUSDCents",
            "fastFinalityFeeUSDCents",
            "finalityTransferFeeBps",
            "fastFinalityTransferFeeBps"
        ];
    }

    /// @dev Resolves the six fee-config fields through the per-field input ladder (see the contract
    ///      natspec): env > declared `v2.feeConfig.<field>` > current on-chain value. lanes{} is
    ///      OWNER INTENT: an env-driven apply never writes it back — the hand-edit hint plus the
    ///      doctor WARN close the loop through a reviewed edit by design.
    function _resolveFeeConfig(
        IPoolV2.TokenTransferFeeConfig memory currentConfig,
        string memory destChainName,
        uint64 destChainSelector
    ) internal view returns (FeeConfigResolution memory res) {
        uint256[NUM_FEE_FIELDS] memory currentValues = [
            uint256(currentConfig.destGasOverhead),
            currentConfig.destBytesOverhead,
            currentConfig.finalityFeeUSDCents,
            currentConfig.fastFinalityFeeUSDCents,
            currentConfig.finalityTransferFeeBps,
            currentConfig.fastFinalityTransferFeeBps
        ];
        string[NUM_FEE_FIELDS] memory envNames = _feeEnvNames();
        string[NUM_FEE_FIELDS] memory fieldNames = _feeFieldNames();

        string memory json;
        (res.configFound, res.configName, json) = _findLocalChainConfig();
        if (res.configFound) (res.laneFound, res.laneKey) = _findLaneKey(json, destChainName, destChainSelector);
        // When no entry matched, notices and hints still name the entry to declare: the remote's
        // config file basename (the key `make add-lane` would write).
        if (!res.laneFound) res.laneKey = _remoteConfigName(destChainName);
        string memory blockPath = string.concat(".lanes.", res.laneKey, ".v2.feeConfig");
        res.blockDeclared = res.laneFound && vm.keyExistsJson(json, blockPath);

        for (uint256 i = 0; i < NUM_FEE_FIELDS; i++) {
            FeeFieldResolution memory f = res.fields[i];
            f.fromEnv = _envExists(envNames[i]);
            if (res.blockDeclared) {
                string memory fieldKey = string.concat(blockPath, ".", fieldNames[i]);
                f.declared = vm.keyExistsJson(json, fieldKey);
                if (f.declared) f.declaredValue = vm.parseJsonUint(json, fieldKey);
            }
            if (f.fromEnv) {
                // Rung 1: the env value wins byte-for-byte; a declared disagreeing field is a
                // notice, never a revert (the doctor WARNs until reconciled).
                f.value = _envUint(envNames[i]);
                f.diverges = f.declared && f.value != f.declaredValue;
            } else if (f.declared) {
                // Rung 2: the declared v2.feeConfig field supplies the value.
                f.fromLanes = true;
                f.value = f.declaredValue;
            } else {
                // Rung 3: the current on-chain value — the historical default.
                f.value = currentValues[i];
            }
            res.anyEnv = res.anyEnv || f.fromEnv;
            res.anyFromLanes = res.anyFromLanes || f.fromLanes;
            res.anyDiverges = res.anyDiverges || f.diverges;
        }

        res.editHint = res.anyEnv && res.configFound && (!res.blockDeclared || res.anyDiverges);

        // Compose the exact strings the console prints, on the struct, so the lane-source tests can
        // pin them byte-exact (mirroring ApplyChainUpdates' `addLaneCommand`).
        for (uint256 i = 0; i < NUM_FEE_FIELDS; i++) {
            if (res.fields[i].diverges) res.fieldNotices[i] = _composeFeeNotice(res, i);
        }
        if (res.editHint) res.editHintText = _composeFeeEditHint(res);
    }

    /// @dev One per-field divergence-notice line (an env-overridden field disagreeing with its
    ///      declaration). Returns the composed string (stored on the struct and printed verbatim) so
    ///      tests can pin it byte-exact.
    function _composeFeeNotice(FeeConfigResolution memory res, uint256 i) internal pure returns (string memory) {
        FeeFieldResolution memory f = res.fields[i];
        return string.concat(
            unicode"⚠️  ",
            _feeEnvNames()[i],
            "=",
            vm.toString(f.value),
            " diverges from declared lanes.",
            res.laneKey,
            ".v2.feeConfig.",
            _feeFieldNames()[i],
            "=",
            vm.toString(f.declaredValue),
            " in config/chains/",
            res.configName,
            ".json - make doctor will WARN until reconciled"
        );
    }

    /// @dev The resolution-ladder console lines: which rung supplied the fields, and one
    ///      divergence notice per env-overridden field that disagrees with its declaration.
    function _logFeeResolution(FeeConfigResolution memory res) internal pure {
        if (res.anyFromLanes) {
            console.log(
                string.concat(
                    "Fee config resolved from lanes.",
                    res.laneKey,
                    ".v2.feeConfig in config/chains/",
                    res.configName,
                    ".json (undeclared fields keep the current on-chain values)"
                )
            );
            console.log("");
        }
        for (uint256 i = 0; i < NUM_FEE_FIELDS; i++) {
            if (res.fields[i].diverges) console.log(res.fieldNotices[i]);
        }
        if (res.anyDiverges) console.log("");
        if (!res.anyEnv && !res.blockDeclared) {
            console.log(
                string.concat(
                    "No fee-config env vars and no declared lanes.",
                    res.laneKey,
                    ".v2.feeConfig",
                    res.configFound ? string.concat(" in config/chains/", res.configName, ".json") : "",
                    "; applying the current on-chain values (historical default). Set the env vars, or declare the block."
                )
            );
            console.log("");
        }
    }

    /// @dev The closing remediation hint. lanes{} is owner intent — applies never auto-write it,
    ///      and `make add-lane` has no flag surface for the v2{} blocks (deliberate), so the hint is
    ///      a hand-edit instruction with the applied values; the doctor WARN closes the loop
    ///      through a reviewed edit.
    function _logFeeEditHint(FeeConfigResolution memory res) internal pure {
        if (!res.editHint) return;
        console.log(res.editHintText);
    }

    /// @dev Composes the closing hand-edit hint. Returns the string (stored on the struct and
    ///      printed verbatim) so tests can pin it byte-exact.
    function _composeFeeEditHint(FeeConfigResolution memory res) internal pure returns (string memory) {
        string[NUM_FEE_FIELDS] memory fieldNames = _feeFieldNames();
        string memory values = "";
        for (uint256 i = 0; i < NUM_FEE_FIELDS; i++) {
            values = string.concat(values, i == 0 ? "" : " ", fieldNames[i], "=", vm.toString(res.fields[i].value));
        }
        return string.concat(
            unicode"⚠️  Applied fee config is ",
            res.blockDeclared ? "diverging from" : "not declared in",
            " lanes.",
            res.laneKey,
            ".v2.feeConfig (config/chains/",
            res.configName,
            ".json). Hand-edit the block to the applied values: ",
            values,
            " - make doctor CHAIN=",
            res.configName,
            " WARNs until reconciled"
        );
    }

    /// @dev Logs the resolved fee config and returns a single-element TokenTransferFeeConfigArgs
    ///      array ready for broadcast. Field values come from the per-field resolution ladder
    ///      (env > declared v2.feeConfig > current on-chain).
    function _buildFeeConfigArgs(FeeConfigResolution memory res, uint64 destChainSelector)
        internal
        pure
        returns (TokenPool.TokenTransferFeeConfigArgs[] memory args)
    {
        // Range-check every RESOLVED value before it is narrowed to the on-chain field width. This
        // guards BOTH env-sourced and lanes-sourced values (the resolution ladder has already picked
        // the final value): an out-of-range value would otherwise be silently truncated into a WRONG
        // live fee. The four fixed-fee fields must fit uint32; the two bps fields must be < 10000
        // (the on-chain BPS_DIVIDER guard reverts on >= 10000, so the valid range is [0-9999]).
        _requireUint32("destGasOverhead", res.fields[0].value);
        _requireUint32("destBytesOverhead", res.fields[1].value);
        _requireUint32("finalityFeeUSDCents", res.fields[2].value);
        _requireUint32("fastFinalityFeeUSDCents", res.fields[3].value);
        _requireBps("finalityTransferFeeBps", res.fields[4].value);
        _requireBps("fastFinalityTransferFeeBps", res.fields[5].value);

        uint32 destGasOverhead = uint32(res.fields[0].value);
        uint32 destBytesOverhead = uint32(res.fields[1].value);
        uint32 defaultFeeUSDCents = uint32(res.fields[2].value);
        uint32 customFeeUSDCents = uint32(res.fields[3].value);
        uint16 defaultTransferFeeBps = uint16(res.fields[4].value);
        uint16 customTransferFeeBps = uint16(res.fields[5].value);

        console.log("Fee Configuration to Apply:");
        console.log(string.concat("  destGasOverhead:              ", vm.toString(destGasOverhead)));
        console.log(string.concat("  destBytesOverhead:            ", vm.toString(destBytesOverhead)));
        console.log(string.concat("  finalityFeeUSDCents:          ", vm.toString(defaultFeeUSDCents)));
        console.log(string.concat("  fastFinalityFeeUSDCents:      ", vm.toString(customFeeUSDCents)));
        console.log(string.concat("  finalityTransferFeeBps:       ", vm.toString(defaultTransferFeeBps)));
        console.log(string.concat("  fastFinalityTransferFeeBps:   ", vm.toString(customTransferFeeBps)));
        console.log("");

        args = new TokenPool.TokenTransferFeeConfigArgs[](1);
        args[0] = TokenPool.TokenTransferFeeConfigArgs({
            destChainSelector: destChainSelector,
            tokenTransferFeeConfig: IPoolV2.TokenTransferFeeConfig({
                destGasOverhead: destGasOverhead,
                destBytesOverhead: destBytesOverhead,
                finalityFeeUSDCents: defaultFeeUSDCents,
                fastFinalityFeeUSDCents: customFeeUSDCents,
                finalityTransferFeeBps: defaultTransferFeeBps,
                fastFinalityTransferFeeBps: customTransferFeeBps,
                isEnabled: true
            })
        });
    }

    /// @dev Reverts, naming the field, the offending value and the allowed range, when a resolved
    ///      fee value does not fit the uint32 on-chain field. Applies to the final resolved value,
    ///      so it guards env-sourced and lanes-sourced values alike.
    function _requireUint32(string memory field, uint256 value) internal pure {
        require(
            value <= type(uint32).max,
            string.concat(
                "Fee-config field ",
                field,
                "=",
                vm.toString(value),
                " is out of range [0-",
                vm.toString(uint256(type(uint32).max)),
                "]; fix the env var or the declared lanes{}.v2.feeConfig value"
            )
        );
    }

    /// @dev Reverts, naming the field, the offending value and the allowed range, when a resolved
    ///      bps value is not in [0-9999]. The on-chain BPS_DIVIDER guard reverts on >= 10000.
    function _requireBps(string memory field, uint256 value) internal pure {
        require(
            value < 10_000,
            string.concat(
                "Fee-config field ",
                field,
                "=",
                vm.toString(value),
                " is out of range [0-9999]; fix the env var or the declared lanes{}.v2.feeConfig value"
            )
        );
    }
}
