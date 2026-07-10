// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/**
 * @title UpdateAuthorizedCallers
 * @notice Script to add or remove authorized callers on an AdvancedPoolHooks or ERC20LockBox contract
 * @dev Calls applyAuthorizedCallerUpdates(AuthorizedCallerArgs) as owner.
 *
 * Usage:
 *   POOL_HOOKS=0x... ADD_ADDRESSES="0xAAA...,0xBBB..." forge script script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   LOCK_BOX=0x...   ADD_ADDRESSES="0xAAA..."          forge script script/configure/authorized-callers/UpdateAuthorizedCallers.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   POOL_HOOKS       — address of an AdvancedPoolHooks contract  (one of POOL_HOOKS or LOCK_BOX required)
 *   LOCK_BOX         — address of an ERC20LockBox contract       (one of POOL_HOOKS or LOCK_BOX required)
 *   ADD_ADDRESSES    — CSV or JSON array of addresses to add
 *   REMOVE_ADDRESSES — CSV or JSON array of addresses to remove
 */
contract UpdateAuthorizedCallers is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        // Resolve the target via the standard ladder (env alias > {CHAIN}_ env > registry), so a freshly
        // deployed hooks/lockbox is targetable with no manual export. This script configures exactly ONE
        // of the two, so when both resolve (e.g. both deployed on this chain) the user must pick via env.
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

        // Parse caller updates — supports CSV ("0xA,0xB") or JSON array ("[\"0xA\",\"0xB\"]")
        address[] memory addCallers = HelperUtils.parseAddressArray(vm, vm.envOr("ADD_ADDRESSES", string("")), "");
        address[] memory removeCallers = HelperUtils.parseAddressArray(vm, vm.envOr("REMOVE_ADDRESSES", string("")), "");

        require(
            addCallers.length > 0 || removeCallers.length > 0,
            "At least one of ADD_ADDRESSES or REMOVE_ADDRESSES must be set"
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"📝 Update Authorized Callers");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat(labelHeader, vm.toString(contractAddress)));
        console.log(string.concat("Action:       ", "Update authorized callers"));
        console.log("========================================");
        console.log("");

        if (addCallers.length > 0) {
            console.log(string.concat("Adding ", vm.toString(addCallers.length), " caller(s):"));
            for (uint256 i = 0; i < addCallers.length; i++) {
                console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(addCallers[i])));
            }
        }
        if (removeCallers.length > 0) {
            console.log(string.concat("Removing ", vm.toString(removeCallers.length), " caller(s):"));
            for (uint256 i = 0; i < removeCallers.length; i++) {
                console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(removeCallers[i])));
            }
        }
        console.log("");

        executeCalls(CctActions.applyAuthorizedCallerUpdates(contractAddress, addCallers, removeCallers));

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Authorized callers updated on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat(labelHeader, vm.toString(contractAddress)));
        console.log(string.concat(labelHeader, helperConfig.getExplorerUrl(chainId, "/address/", contractAddress)));
        console.log("========================================");
        console.log("");
    }
}
