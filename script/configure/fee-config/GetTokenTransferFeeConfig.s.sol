// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";

/// @notice Reads and displays the token transfer fee configuration for a token pool on a given destination lane.
///
/// @dev This function is only available on TokenPool v2.0 and later. Prior to v2.0, fee configuration
///      is managed by FeeQuoter and configured directly by the Chainlink team upon token issuer request.
///      If the pool does not support this function, the script will revert with an informative message.
///
/// Environment Variables (required):
///   DEST_CHAIN    - The remote destination chain whose fee config is being queried (e.g. MANTLE_SEPOLIA)
///
/// Usage example:
///   DEST_CHAIN=MANTLE_SEPOLIA \
///   forge script script/configure/fee-config/GetTokenTransferFeeConfig.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetTokenTransferFeeConfig is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Required env vars ──────────────────────────────────────────────
        string memory destChainName = vm.envString("DEST_CHAIN");

        // ── Resolve chain IDs and selectors ───────────────────────────────
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

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"💰 Get Token Transfer Fee Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Remote Chain: ", helperConfig.getChainName(destChainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View fee config"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Dest Chain Selector: ", vm.toString(destChainSelector)));
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        // ── Query fee config (v2.0+ only) ──────────────────────────────────
        // getTokenTransferFeeConfig() was introduced in TokenPool v2.0.
        // On v1 pools, fee configuration is handled by FeeQuoter and requires
        // a direct request to the Chainlink team - it cannot be read or set here.
        try tokenPool.getTokenTransferFeeConfig(address(0), destChainSelector, 0, "") returns (
            IPoolV2.TokenTransferFeeConfig memory feeConfig
        ) {
            console.log("Fee Configuration:");
            console.log(string.concat("  isEnabled:                    ", feeConfig.isEnabled ? "true" : "false"));
            console.log(string.concat("  destGasOverhead:              ", vm.toString(feeConfig.destGasOverhead)));
            console.log(string.concat("  destBytesOverhead:            ", vm.toString(feeConfig.destBytesOverhead)));
            console.log(string.concat("  finalityFeeUSDCents:          ", vm.toString(feeConfig.finalityFeeUSDCents)));
            console.log(
                string.concat("  fastFinalityFeeUSDCents:      ", vm.toString(feeConfig.fastFinalityFeeUSDCents))
            );
            console.log(
                string.concat("  finalityTransferFeeBps:       ", vm.toString(feeConfig.finalityTransferFeeBps))
            );
            console.log(
                string.concat("  fastFinalityTransferFeeBps:   ", vm.toString(feeConfig.fastFinalityTransferFeeBps))
            );

            if (!feeConfig.isEnabled) {
                console.log("");
                console.log(unicode"⚠️  Fee config is disabled for this lane.");
                console.log("   The OnRamp will fall back to FeeQuoter defaults for this destination.");
            }
        } catch (bytes memory err) {
            console.log(unicode"❌ Error: getTokenTransferFeeConfig() reverted.");
            console.log("   Raw revert data:");
            console.logBytes(err);
            console.log("   If the function selector is missing, the pool may be v1 (requires TokenPool v2.0+).");
            revert("getTokenTransferFeeConfig() reverted - see raw error above");
        }

        // ── Footer ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        console.log("========================================");
        console.log("");
    }
}
