// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";

/**
 * @title GetAuthorizedCallers
 * @notice Script to fetch and print the authorized callers from an AdvancedPoolHooks or ERC20LockBox contract
 *
 * Usage:
 *   POOL_HOOKS=0x... forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 *   LOCK_BOX=0x...   forge script script/configure/authorized-callers/GetAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME
 *
 * Environment variables:
 *   POOL_HOOKS -- address of an AdvancedPoolHooks contract  (one of POOL_HOOKS or LOCK_BOX required)
 *   LOCK_BOX   -- address of an ERC20LockBox contract       (one of POOL_HOOKS or LOCK_BOX required)
 */
contract GetAuthorizedCallers is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // Resolve the target via the standard ladder (env alias > {CHAIN}_ env > registry), so a freshly
        // deployed hooks/lockbox is readable with no manual export. This script reads exactly ONE of the
        // two, so when both resolve the user must pick via env.
        address poolHooks = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));
        address lockBox = vm.envOr("LOCK_BOX", helperConfig.getDeployedLockBox(chainId));
        require(
            poolHooks != address(0) || lockBox != address(0),
            "No POOL_HOOKS or LOCK_BOX resolved (env or registry). Set one, or deploy hooks/a lockbox first."
        );
        require(
            poolHooks == address(0) || lockBox == address(0),
            "Both POOL_HOOKS and LOCK_BOX resolved (env or registry). Set exactly one explicitly to disambiguate."
        );

        bool isLockBox = lockBox != address(0);
        address contractAddress = isLockBox ? lockBox : poolHooks;
        string memory labelHeader = isLockBox ? "LockBox:      " : "Pool Hooks:   ";

        console.log("");
        console.log("========================================");
        console.log(unicode"🔎 Get Authorized Callers");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat(labelHeader, vm.toString(contractAddress)));
        console.log(string.concat("Action:       ", "View authorized callers"));
        console.log("========================================");
        console.log("");

        address[] memory callers = AuthorizedCallers(contractAddress).getAllAuthorizedCallers();
        console.log(string.concat("Authorized Callers count: ", vm.toString(callers.length)));
        for (uint256 i = 0; i < callers.length; i++) {
            console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(callers[i])));
        }
        console.log("========================================");
        console.log(string.concat(labelHeader, helperConfig.getExplorerUrl(chainId, "/address/", contractAddress)));
        console.log("========================================");
        console.log("");
    }
}
