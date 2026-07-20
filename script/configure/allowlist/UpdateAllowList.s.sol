// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {HelperUtils} from "../../utils/HelperUtils.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/**
 * @title UpdateAllowList
 * @notice Script to update the allowlist for a TokenPool or AdvancedPoolHooks
 * @dev Calls applyAllowListUpdates(removes, adds) as owner
 *
 * Usage:
 *   TOKEN_POOL=0x... POOL_HOOKS=0x... forge script script/configure/allowlist/UpdateAllowList.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   (If POOL_HOOKS is not set, will try to call on pool contract. If not found, throws error with guidance.)
 */
contract UpdateAllowList is EoaExecutor {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address tokenPoolAddress = vm.envOr("TOKEN_POOL", helperConfig.getDeployedTokenPool(chainId));
        // POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > registry active.poolHooks. Optional: unset (0x0) targets
        // the pool itself (v1 allowlist); a resolved hooks address targets the v2 AdvancedPoolHooks.
        address hooksAddress = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));

        require(
            tokenPoolAddress != address(0),
            string.concat(
                "Token pool not deployed. Set TOKEN_POOL env var or ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL."
            )
        );

        // Parse allowlist updates - supports CSV ("0xA,0xB") or JSON array ("[\"0xA\",\"0xB\"]")
        address[] memory removes = HelperUtils._parseAddressArray(vm, vm.envOr("REMOVE_ADDRESSES", string("")), "");
        address[] memory adds = HelperUtils._parseAddressArray(vm, vm.envOr("ADD_ADDRESSES", string("")), "");

        console.log("");
        console.log("========================================");
        console.log(unicode"📝 Update AllowList");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token Pool:   ", vm.toString(tokenPoolAddress)));
        if (hooksAddress != address(0)) {
            console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        }
        console.log(string.concat("Action:       ", "Update allowlist"));
        console.log("========================================");
        console.log("");

        // Target the AdvancedPoolHooks (v2) when POOL_HOOKS is set, otherwise the pool itself (v1). Both
        // expose the identical applyAllowListUpdates(address[],address[]) selector, so one builder serves
        // both. A revert (e.g. OnlyCallableByOwner, or a v2 pool without hooks) bubbles up unchanged.
        address allowListTarget = hooksAddress != address(0) ? hooksAddress : tokenPoolAddress;
        _executeCalls(CctActions._applyAllowListUpdates(allowListTarget, removes, adds));

        console.log(unicode"✅ AllowList updated successfully!");
        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Allowlist updated on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat("Token Pool:   ", helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress))
        );
        if (hooksAddress != address(0)) {
            console.log(
                string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress))
            );
        }
        console.log("========================================");
        console.log("");
    }
}
