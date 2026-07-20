// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/interfaces/IAdvancedPoolHooks.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";

/// @notice Reads and displays the CCV (Cross-Chain Verifier) configuration for a token pool: every
///         configured remote lane's four verifier arrays plus the pool-global additional-CCV threshold.
///
/// @dev CCVs live on the pool's `AdvancedPoolHooks` contract, which only exists on TokenPool v2.0 and
///      later (`TokenPool.getAdvancedPoolHooks()`) and may be unset (`address(0)`) when no hooks are
///      wired. This is a version-fenced read that degrades gracefully: a pre-2.0.0 pool prints a named
///      message (CCVs are not cataloged before 2.0.0), and a 2.0.0 pool without hooks prints a clean
///      "nothing to read" message - neither is a revert.
///
/// Usage example:
///   forge script script/configure/ccv/GetCCVConfig.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetCCVConfig is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Resolve chain + pool ───────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;

        address tokenPoolAddress = helperConfig.getDeployedTokenPool(chainId);
        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );
        _display(chainId, tokenPoolAddress);
    }

    /// @notice Test hook: runs the read/display path against an explicit `pool` on the currently
    ///         selected fork, without the registry/env pool resolution. Lets a fork test exercise the
    ///         configured-hooks and graceful-no-hooks paths without a process-global TOKEN_POOL env
    ///         var. Not used by any production path.
    function displayForTest(address pool) external {
        helperConfig = new HelperConfig();
        _display(block.chainid, pool);
    }

    /// @dev The read/display body: version fence, hooks resolution, and the CCV surface dump. Shared
    ///      by `run()` (registry/env pool) and `displayForTest` (explicit pool).
    function _display(uint256 chainId, address tokenPoolAddress) private view {
        string memory chainName = helperConfig.getChainName(chainId);

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🛡️  Get CCV Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View CCV config"));
        console.log("========================================");
        console.log("");

        // ── Version fence (read path: degrade, never revert) ───────────────
        // CCVs are a v2.0-only surface (they live on AdvancedPoolHooks). A pre-2.0.0 or unrecognized
        // pool prints a named message and returns cleanly.
        (bool versionKnown, PoolVersions.Version version, string memory typeAndVersion) =
            PoolVersion._tryResolve(tokenPoolAddress);
        if (!versionKnown || version < PoolVersions.Version.V2_0_0) {
            console.log(
                string.concat(
                    unicode"ℹ️  Pool reports \"",
                    typeAndVersion,
                    versionKnown ? "\" (pre-2.0.0)" : "\" (uncataloged)",
                    " - CCV config is a TokenPool 2.0.0 surface (AdvancedPoolHooks); nothing to read here."
                )
            );
            _footer(chainId, tokenPoolAddress);
            return;
        }

        // ── Resolve the hooks contract ─────────────────────────────────────
        // The read path never reverts: a pool that reverts on `getAdvancedPoolHooks` (rather than
        // returning address(0)) degrades to the same graceful no-hooks message.
        address hooksAddress;
        try TokenPool(tokenPoolAddress).getAdvancedPoolHooks() returns (IAdvancedPoolHooks hooks) {
            hooksAddress = address(hooks);
        } catch {
            _logNoHooks("getAdvancedPoolHooks() reverted on this pool; the CCV hooks surface is not readable here");
            _footer(chainId, tokenPoolAddress);
            return;
        }
        if (hooksAddress == address(0)) {
            _logNoHooks("No AdvancedPoolHooks contract is wired to this pool");
            _footer(chainId, tokenPoolAddress);
            return;
        }

        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Hooks Owner:  ", vm.toString(AdvancedPoolHooks(hooksAddress).owner())));
        console.log("");

        // ── Read the CCV surface ───────────────────────────────────────────
        AdvancedPoolHooks.CCVConfigArg[] memory configs = AdvancedPoolHooks(hooksAddress).getAllCCVConfigs();
        uint256 threshold = AdvancedPoolHooks(hooksAddress).getThresholdAmount();

        console.log(
            string.concat(
                "Global additional-CCV threshold: ", threshold == 0 ? "0 (no threshold)" : vm.toString(threshold)
            )
        );
        console.log("");

        if (configs.length == 0) {
            console.log("No per-lane CCV configuration is stored on the hooks contract.");
        } else {
            console.log(string.concat("Configured lanes: ", vm.toString(configs.length)));
            for (uint256 i = 0; i < configs.length; i++) {
                _logLane(configs[i]);
            }
        }

        _footer(chainId, tokenPoolAddress);
    }

    /// @dev One configured lane: the remote selector (resolved to its chain name when a config declares
    ///      it) and its four verifier arrays.
    function _logLane(AdvancedPoolHooks.CCVConfigArg memory cfg) private view {
        string memory remoteName = helperConfig.getChainNameBySelector(cfg.remoteChainSelector);
        console.log(string.concat("  Lane selector ", vm.toString(cfg.remoteChainSelector), " (", remoteName, "):"));
        _logArray("outboundCCVs         ", cfg.outboundCCVs);
        _logArray("thresholdOutboundCCVs", cfg.thresholdOutboundCCVs);
        _logArray("inboundCCVs          ", cfg.inboundCCVs);
        _logArray("thresholdInboundCCVs ", cfg.thresholdInboundCCVs);
    }

    /// @dev One verifier array, one address per line (compact "[]" when empty).
    function _logArray(string memory label, address[] memory arr) private pure {
        if (arr.length == 0) {
            console.log(string.concat("    ", label, ": []"));
            return;
        }
        console.log(string.concat("    ", label, ": ", vm.toString(arr.length)));
        for (uint256 i = 0; i < arr.length; i++) {
            console.log(string.concat("      [", vm.toString(i), "] ", vm.toString(arr[i])));
        }
    }

    /// @dev The graceful "no CCV surface to read" message, sharing the setter's `_fencedHooks` wording
    ///      so the operator sees the full deploy + wire scripts and the `NEW_HOOK=<addr>` arg (not bare
    ///      basenames). Used both when no hooks are wired and when the hooks read itself reverts.
    function _logNoHooks(string memory reason) private pure {
        console.log(
            string.concat(unicode"ℹ️  ", reason, " - CCV config lives on the hooks contract; nothing to read.")
        );
        console.log(
            "   Deploy one (script/configure/allowlist/DeployAdvancedPoolHooks.s.sol) and wire it (script/configure/allowlist/UpdateAdvancedPoolHooks.s.sol, NEW_HOOK=<addr>) before configuring CCVs."
        );
    }

    function _footer(uint256 chainId, address tokenPoolAddress) private view {
        console.log("");
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
