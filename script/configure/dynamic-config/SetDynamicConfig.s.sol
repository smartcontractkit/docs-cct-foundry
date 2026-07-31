// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @notice Updates the dynamic configuration of a TokenPool (router, rateLimitAdmin, feeAdmin).
///
/// Environment Variables (optional):
///   ROUTER           - The new router address (default: current on-chain value)
///   RATE_LIMIT_ADMIN - The new rate limit admin address (default: current on-chain value)
///   FEE_ADMIN        - The new fee admin address (default: current on-chain value)
///                      Set to address(0) to restrict fee withdrawal to the owner only.
///
/// An unset variable preserves the pool's current value verbatim, address(0) included: this script
/// writes the whole struct, so anything else would turn a one-field update into a silent grant of the
/// other fields (a broadcaster fallback would hand both admin slots to the acting account on a
/// ROUTER-only run whenever they are unset on chain).
///
/// Usage example:
///   ROUTER=0xYourRouterAddress \
///   RATE_LIMIT_ADMIN=0xYourRateLimitAdminAddress \
///   FEE_ADMIN=0xYourFeeAdminAddress \
///   forge script script/configure/dynamic-config/SetDynamicConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetDynamicConfig is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev An unset variable preserves the current on-chain value VERBATIM, address(0) included. The
    ///      call writes the whole struct, so any other default turns a one-field update into a silent
    ///      grant of the others: a broadcaster fallback would hand both admin slots to the acting
    ///      account on a ROUTER-only run whenever they are unset on chain.
    function _resolveNewConfig(address currentRouter, address currentRateLimitAdmin, address currentFeeAdmin)
        internal
        view
        returns (address router, address rateLimitAdmin, address feeAdmin)
    {
        router = _dcEnvOr("ROUTER", currentRouter);
        rateLimitAdmin = _dcEnvOr("RATE_LIMIT_ADMIN", currentRateLimitAdmin);
        feeAdmin = _dcEnvOr("FEE_ADMIN", currentFeeAdmin);
    }

    /// @dev Virtual input seam (like the `_rlEnv*` seams elsewhere): env vars are process-wide and
    ///      suites run in parallel, so tests pin the resolution through an override, never `vm.setEnv`.
    function _dcEnvOr(string memory name, address defaultValue) internal view virtual returns (address) {
        return vm.envOr(name, defaultValue);
    }

    function run() external {
        // ── Resolve chain ID ──────────────────────────────────────────────
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

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

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // ── Read current config for display ───────────────────────────────
        (address currentRouter, address currentRateLimitAdmin, address currentFeeAdmin) = tokenPool.getDynamicConfig();

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⚙️  Set Dynamic Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "Set dynamic config"));
        console.log("========================================");
        console.log("");
        console.log("Current Configuration:");
        console.log(string.concat("  Router:                       ", vm.toString(currentRouter)));
        console.log(string.concat("  Rate Limit Admin:             ", vm.toString(currentRateLimitAdmin)));
        console.log(string.concat("  Fee Admin:                    ", vm.toString(currentFeeAdmin)));
        console.log("");

        (address router, address rateLimitAdmin, address feeAdmin) =
            _resolveNewConfig(currentRouter, currentRateLimitAdmin, currentFeeAdmin);

        console.log("New Configuration:");
        console.log(string.concat("  Router:                       ", vm.toString(router)));
        console.log(string.concat("  Rate Limit Admin:             ", vm.toString(rateLimitAdmin)));
        console.log(string.concat("  Fee Admin:                    ", vm.toString(feeAdmin)));
        console.log("");
        console.log(string.concat("[Step 1] Setting dynamic config on ", chainName));

        _executeCalls(CctActions._setDynamicConfig(tokenPoolAddress, router, rateLimitAdmin, feeAdmin));

        console.log(unicode"✅ Dynamic config updated successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Configuration Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool:       ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Router:           ", vm.toString(router)));
        console.log(string.concat("Rate Limit Admin: ", vm.toString(rateLimitAdmin)));
        console.log(string.concat("Fee Admin:        ", vm.toString(feeAdmin)));
        console.log(
            string.concat("Token Pool:       ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
