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
///   RATE_LIMIT_ADMIN - The new rate limit admin address
///                      Default: current on-chain value (if set), otherwise the broadcaster address.
///   FEE_ADMIN        - The new fee admin address
///                      Default: current on-chain value (if set), otherwise the broadcaster address.
///                      Set to address(0) to restrict fee withdrawal to the owner only.
///
/// Usage example:
///   ROUTER=0xYourRouterAddress \
///   RATE_LIMIT_ADMIN=0xYourRateLimitAdminAddress \
///   FEE_ADMIN=0xYourFeeAdminAddress \
///   forge script script/configure/dynamic-config/SetDynamicConfig.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract SetDynamicConfig is EoaExecutor {
    HelperConfig public helperConfig;

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

        // Defaults: env var → current on-chain value → broadcaster (as last resort if unset)
        address broadcasterAddr = _broadcaster();
        address router = vm.envOr("ROUTER", currentRouter);
        address rateLimitAdmin =
            vm.envOr("RATE_LIMIT_ADMIN", currentRateLimitAdmin != address(0) ? currentRateLimitAdmin : broadcasterAddr);
        address feeAdmin = vm.envOr("FEE_ADMIN", currentFeeAdmin != address(0) ? currentFeeAdmin : broadcasterAddr);

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
