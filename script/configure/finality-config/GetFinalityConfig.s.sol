// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {FinalityConfigUtils} from "../../utils/FinalityConfigUtils.s.sol";

/// @notice Reads and displays the allowed finality configuration on a TokenPool.
///
/// @dev This function is only available on TokenPool v2.0 and later.
/// The allowed finality config controls which fast finality modes are accepted for cross-chain transfers.
/// Encoded as a bytes4 value per the FinalityCodec library:
///   0x00000000  - WAIT_FOR_FINALITY (default): full finality required; fast finality transfers disabled.
///   0x00010000  - WAIT_FOR_SAFE: fast finality transfers wait for the `safe` head.
///   0x0000NNNN  - BLOCK_DEPTH(N): fast finality transfers wait for N block confirmations (1–65535).
///
/// Usage example:
///   forge script script/configure/finality-config/GetFinalityConfig.s.sol \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetFinalityConfig is Script {
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

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"⏱️  Get Finality Config");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View finality config"));
        console.log("========================================");
        console.log("");

        TokenPool tokenPool = TokenPool(tokenPoolAddress);

        try tokenPool.getAllowedFinalityConfig() returns (bytes4 allowedFinality) {
            FinalityConfigUtils._logFinalityConfig(allowedFinality);
        } catch (bytes memory err) {
            console.log(
                unicode"❌ Error: getAllowedFinalityConfig() reverted. Pool may be v1 (requires TokenPool v2.0+)."
            );
            console.log("  Raw revert data:");
            console.logBytes(err);
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
