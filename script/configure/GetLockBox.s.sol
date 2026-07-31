// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Reads and displays the ERC20LockBox contract address currently attached to a LockReleaseTokenPool.
///
/// @dev getLockBox() is only available on LockReleaseTokenPool v2.0 and later.
///
/// Usage example:
///   forge script script/configure/GetLockBox.s.sol \
///     --rpc-url $MANTLE_SEPOLIA_RPC_URL
contract GetLockBox is Script {
    HelperConfig public helperConfig;

    function run() external {
        // ── Resolve chain and pool ───────────────────────────────────────────
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

        // ── Header ─────────────────────────────────────────────────────────
        console.log("");
        console.log("========================================");
        console.log(unicode"🔒 Get LockBox");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        console.log(string.concat("Action:       ", "View lockbox"));
        console.log("========================================");
        console.log("");

        // ── Query lockbox ──────────────────────────────────────────────────
        // getLockBox() is only available on LockReleaseTokenPool v2.0 and later.
        try LockReleaseTokenPool(tokenPoolAddress).getLockBox() returns (address lockBox) {
            if (lockBox == address(0)) {
                console.log("No LockBox is attached to this pool.");
            } else {
                console.log(unicode"✅ LockBox:");
                console.log(string.concat("   ", vm.toString(lockBox)));

                // Read token and balance held by the lockbox
                try ERC20LockBox(lockBox).getToken() returns (IERC20 token) {
                    address tokenAddress = address(token);
                    uint256 balance = token.balanceOf(lockBox);

                    string memory symbol = "";
                    try IERC20Metadata(tokenAddress).symbol() returns (string memory s) {
                        symbol = string.concat(" (", s, ")");
                    } catch {}

                    console.log(string.concat("   Token:   ", vm.toString(tokenAddress), symbol));
                    console.log(string.concat("   Balance: ", vm.toString(balance)));
                } catch {
                    // Catching silently would leave a lockbox whose token cannot be read looking like one
                    // with nothing worth printing. The lockbox address above holds either way, so name
                    // the part that is missing.
                    console.log("   Token:   could not be read from the lockbox");
                    console.log("   Balance: unknown (it is read through the token)");
                }
            }
        } catch (bytes memory err) {
            console.log(unicode"❌ Error: getLockBox() reverted.");
            console.log("   Raw revert data:");
            console.logBytes(err);
            console.log(
                "   If the function selector is missing, the pool may be v1 (requires LockReleaseTokenPool v2.0+)."
            );
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
