// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";

/**
 * @title DepositToLockBox
 * @notice Script to deposit tokens into an ERC20LockBox
 * @dev Useful for token issuers to manually manage liquidity in the lockbox.
 *      Requires the caller to be an authorized caller on the lockbox.
 *
 * Usage:
 *   LOCK_BOX=0x... forge script script/operations/DepositToLockBox.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   LOCK_BOX   - (required) address of the ERC20LockBox contract
 *   AMOUNT     - (optional) amount to deposit (defaults to tokenAmountToTransfer from script/input/token.json)
 */
contract DepositToLockBox is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev LockBox resolution seam: `LOCK_BOX` alias > `{CHAIN}_LOCK_BOX` > registry `active.lockBox`
    /// (no manual export needed). `virtual` so a test can inject an unresolved (`address(0)`) result and
    /// assert the named revert DETERMINISTICALLY, independent of the process-wide env other parallel
    /// suites set - the ladder itself is proven in `test/config/RegistryResolution.t.sol`.
    function _resolveLockBox(uint256 chainId) internal virtual returns (address) {
        return vm.envOr("LOCK_BOX", helperConfig.getDeployedLockBox(chainId));
    }

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address lockBoxAddress = _resolveLockBox(chainId);
        require(
            lockBoxAddress != address(0),
            "LockBox not deployed. Set LOCK_BOX or the {CHAIN}_LOCK_BOX environment variable."
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"📥 Deposit to LockBox");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("LockBox:      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("Action:       ", "Deposit to lockbox"));
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

        // Get amount to deposit - falls back to tokenAmountToTransfer in script/input/token.json if not set
        string memory tokenJson = vm.readFile("script/input/token.json");
        uint256 defaultAmount = vm.parseJsonUint(tokenJson, ".tokenAmountToTransfer");
        uint256 amount = vm.envOr("AMOUNT", defaultAmount);
        require(
            amount > 0,
            "Invalid amount to deposit. Set AMOUNT env var or tokenAmountToTransfer in script/input/token.json"
        );

        IERC20 token = IERC20(tokenAddress);

        address depositor = _broadcaster();

        console.log("Deposit Parameters:");
        console.log(string.concat("  LockBox:                      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Depositor:                    ", vm.toString(depositor)));
        console.log(string.concat("  Amount:                       ", vm.toString(amount)));
        console.log("");

        uint256 balanceBefore = token.balanceOf(depositor);
        require(balanceBefore >= amount, "Insufficient token balance");

        // approve(lockbox, amount) then deposit(token, 0, amount) as one batch through the action layer.
        console.log(string.concat("[Step 1] Approving ", vm.toString(amount), " tokens to LockBox"));
        console.log(string.concat("[Step 2] Depositing ", vm.toString(amount), " tokens into LockBox"));
        _executeCalls(CctActions._lockboxDeposit(lockBoxAddress, tokenAddress, amount));
        console.log(unicode"✅ Deposit successful!");

        uint256 balanceAfter = token.balanceOf(depositor);
        uint256 lockBoxBalance = token.balanceOf(lockBoxAddress);

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deposit Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Depositor Balance Before: ", vm.toString(balanceBefore)));
        console.log(string.concat("Depositor Balance After: ", vm.toString(balanceAfter)));
        console.log(string.concat("LockBox Balance: ", vm.toString(lockBoxBalance)));
        console.log("========================================");
        console.log("");
    }
}
