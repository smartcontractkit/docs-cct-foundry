// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/**
 * @title WithdrawFromLockBox
 * @notice Script to withdraw tokens from an ERC20LockBox
 * @dev Useful for token issuers to manually manage liquidity in the lockbox.
 *      Requires the caller to be an authorized caller on the lockbox.
 *
 * Usage:
 *   LOCK_BOX=0x... forge script script/operations/WithdrawFromLockBox.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   LOCK_BOX   — (required) address of the ERC20LockBox contract
 *   AMOUNT     — (optional) amount to withdraw (defaults to entire lockbox balance)
 *   RECIPIENT  — (optional) address to receive withdrawn tokens (defaults to broadcaster)
 */
contract WithdrawFromLockBox is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // LOCK_BOX alias > {CHAIN}_LOCK_BOX > registry active.lockBox (no manual export needed).
        address lockBoxAddress = vm.envOr("LOCK_BOX", helperConfig.getDeployedLockBox(chainId));
        require(
            lockBoxAddress != address(0),
            "LockBox not deployed. Set LOCK_BOX or the {CHAIN}_LOCK_BOX environment variable."
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"📤 Withdraw from LockBox");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("LockBox:      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("Action:       ", "Withdraw from lockbox"));
        console.log("========================================");
        console.log("");

        ERC20LockBox lockBox = ERC20LockBox(lockBoxAddress);

        // Get token address from HelperConfig
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN environment variable. Alternatively, use the inline alias TOKEN=0x..."
            )
        );

        // Verify lockbox supports this token
        require(lockBox.isTokenSupported(tokenAddress), "Token not supported by this lockbox");

        IERC20 token = IERC20(tokenAddress);

        // Check lockbox balance to determine default withdrawal amount
        uint256 lockBoxBalance = token.balanceOf(lockBoxAddress);
        require(lockBoxBalance > 0, "LockBox has no tokens");

        // Get amount to withdraw — defaults to entire lockbox balance
        uint256 amount = vm.envOr("AMOUNT", lockBoxBalance);
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= lockBoxBalance, "Amount exceeds lockbox balance");

        address recipient = vm.envOr("RECIPIENT", broadcaster());

        console.log("Withdrawal Parameters:");
        console.log(string.concat("  LockBox:                      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Recipient:                    ", vm.toString(recipient)));
        console.log(string.concat("  LockBox Balance:              ", vm.toString(lockBoxBalance)));
        console.log(
            string.concat(
                "  Amount to Withdraw:           ",
                vm.toString(amount),
                amount == lockBoxBalance ? " (entire balance)" : ""
            )
        );
        console.log("");

        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        console.log(string.concat("[Step 1] Withdrawing ", vm.toString(amount), " tokens from LockBox"));
        executeCalls(CctActions.lockboxWithdraw(lockBoxAddress, tokenAddress, amount, recipient));
        console.log(unicode"✅ Withdrawal successful!");

        uint256 lockBoxBalanceAfter = token.balanceOf(lockBoxAddress);
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        uint256 actualWithdrawn = recipientBalanceAfter - recipientBalanceBefore;

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Withdrawal Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Amount Withdrawn: ", vm.toString(actualWithdrawn)));
        console.log(string.concat("LockBox Balance Before: ", vm.toString(lockBoxBalance)));
        console.log(string.concat("LockBox Balance After: ", vm.toString(lockBoxBalanceAfter)));
        console.log(string.concat("Recipient Balance Before: ", vm.toString(recipientBalanceBefore)));
        console.log(string.concat("Recipient Balance After: ", vm.toString(recipientBalanceAfter)));
        console.log("========================================");
        console.log("");
    }
}
