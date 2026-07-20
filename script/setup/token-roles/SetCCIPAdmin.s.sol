// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {TokenRoleScript} from "./TokenRoleScript.s.sol";
import {RolesProbes} from "../../../src/roles/RolesProbes.sol";

/**
 * @notice Sets the token's CCIP admin (`setCCIPAdmin`, one-step, no accept). The CCIP admin is the
 *         address `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin` registers as the token's
 *         TAR administrator; moving it is part of the roles handoff.
 *
 * Optional env vars:
 *   TOKEN              - token address (defaults to the {CHAIN}_TOKEN / registry resolution ladder)
 *   CCIP_ADMIN_ADDRESS - the new CCIP admin (defaults to the executing account: the Safe in MODE=safe)
 *
 * Usage:
 *   CCIP_ADMIN_ADDRESS=0xSafe \
 *     forge script script/setup/token-roles/SetCCIPAdmin.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract SetCCIPAdmin is TokenRoleScript {
    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address token = _resolveToken(config, chainId);

        (bool hasGetter, address current) = RolesProbes._tryAddress(token, "getCCIPAdmin()");
        require(hasGetter, "Token exposes no getCCIPAdmin() - it has no CCIP admin slot to set.");

        RolesProbes.TokenTemplate template = RolesProbes._detectTemplate(token);
        address actor = _executingAccount();
        address newAdmin = _newCcipAdmin(actor);
        require(newAdmin != address(0), "CCIP_ADMIN_ADDRESS must be a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(unicode"🛡️ Set CCIP Admin");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token:        ", vm.toString(token)));
        console.log(string.concat("Template:     ", RolesProbes._templateName(template)));
        console.log(string.concat("Current:      ", vm.toString(current)));
        console.log(string.concat("New Admin:    ", vm.toString(newAdmin)));
        console.log(string.concat("Actor:        ", vm.toString(actor)));
        console.log("========================================");
        console.log("");

        // Authority preflight per template: crosschain/burnmint gate setCCIPAdmin with
        // DEFAULT_ADMIN_ROLE; the factory template with owner(). A BYO token's gate is unknown -
        // the simulation run (no --broadcast) surfaces an unauthorized actor before anything is sent.
        if (template == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            (, address owner_) = RolesProbes._tryAddress(token, "owner()");
            require(
                owner_ == actor,
                string.concat(
                    "Executing account (", vm.toString(actor), ") is not the token owner (", vm.toString(owner_), ")."
                )
            );
        } else if (template != RolesProbes.TokenTemplate.BYO) {
            require(
                RolesProbes._hasRole(token, RolesProbes.DEFAULT_ADMIN_ROLE, actor),
                string.concat(
                    "Executing account (", vm.toString(actor), ") does not hold DEFAULT_ADMIN_ROLE on this token."
                )
            );
        }

        console.log(string.concat("\n[Step 1] Setting CCIP admin on ", chainName));
        _executeCalls(CctActions._setCCIPAdmin(token, newAdmin));
        console.log(unicode"✅ CCIP admin set successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ CCIP Admin Set on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token:      ", helperConfig.getExplorerUrl(chainId, "/address/", token)));
        console.log(string.concat("CCIP Admin: ", vm.toString(newAdmin)));
        console.log("========================================");
        console.log("");
    }

    /// @dev Virtual input seam (like `_executionMode`): the env var is process-wide, so tests pin the
    ///      new admin via an override instead of `vm.setEnv` (which would race parallel suites).
    function _newCcipAdmin(address defaultAdmin_) internal view virtual returns (address) {
        return vm.envOr("CCIP_ADMIN_ADDRESS", defaultAdmin_);
    }
}
