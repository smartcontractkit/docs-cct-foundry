// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {TokenRoleScript} from "./TokenRoleScript.s.sol";
import {RolesProbes} from "../../../src/roles/RolesProbes.sol";

/**
 * @notice Revokes a token role (minter / burner / burnMintAdmin) from a holder, template-dispatched
 *         exactly like `GrantTokenRole`: `revokeRole` on AccessControl templates,
 *         `revokeMintRole`/`revokeBurnRole` on the Ownable `factory` template. Revoking a role the
 *         holder does not hold is a no-op on every template — a ceremony re-run never reverts here.
 *
 * Required env vars:
 *   ROLE    — one of: minter, burner, burnMintAdmin, defaultAdmin (burnMintAdmin exists only on
 *             crosschain; defaultAdmin only on burnmint — the ceremony's step-C admin revoke)
 *   HOLDER  — the address to revoke FROM. REQUIRED, deliberately no default: under MODE=safe the
 *             executing-account default would make the Safe itself the revoke target — the exact
 *             inversion the handoff ceremony forbids (revoking the recipient's fresh grant). The
 *             executing account itself is refused as HOLDER (self-revocation can strand the token).
 *
 * Optional env vars:
 *   TOKEN   — token address (defaults to the {CHAIN}_TOKEN / registry resolution ladder)
 *
 * Usage:
 *   ROLE=minter HOLDER=0xOldHolder \
 *     forge script script/setup/token-roles/RevokeTokenRole.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract RevokeTokenRole is TokenRoleScript {
    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address token = _resolveToken(config, chainId);

        RolesProbes.TokenRole role = RolesProbes.tokenRoleFromName(_roleName());
        RolesProbes.TokenTemplate template = RolesProbes.detectTemplate(token);
        RolesProbes.requireRoleOnTemplate(template, role);

        address holder = _holder();
        require(
            holder != address(0),
            "HOLDER must be set. RevokeTokenRole never defaults the revoke target: under MODE=safe the default executing account is the Safe itself, and revoking the recipient is the inversion the handoff forbids."
        );

        address actor = executingAccount();
        require(
            holder != actor,
            "HOLDER is the executing account itself. Self-revocation is refused: revoking your own DEFAULT_ADMIN_ROLE (or your own mint/burn authority) can strand the token with no working admin, and no ceremony step revokes from the actor."
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🚫 Revoke Token Role");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token:        ", vm.toString(token)));
        console.log(string.concat("Template:     ", RolesProbes.templateName(template)));
        console.log(string.concat("Role:         ", RolesProbes.tokenRoleName(role)));
        console.log(string.concat("Holder:       ", vm.toString(holder)));
        console.log(string.concat("Actor:        ", vm.toString(actor)));
        console.log("========================================");
        console.log("");

        requireTokenRoleAuthority(token, template, role, actor);

        console.log(string.concat("\n[Step 1] Revoking ", RolesProbes.tokenRoleName(role), " on ", chainName));
        if (template == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            // Only Minter/Burner reach this branch (requireRoleOnTemplate refused the admin roles on
            // factory); the explicit check keeps a future role from silently mapping to revokeBurnRole.
            if (role == RolesProbes.TokenRole.Minter) {
                executeCalls(CctActions.revokeMintRole(token, holder));
            } else {
                require(role == RolesProbes.TokenRole.Burner, "factory tokens carry only minter/burner roles");
                executeCalls(CctActions.revokeBurnRole(token, holder));
            }
        } else {
            executeCalls(CctActions.revokeRole(token, RolesProbes.tokenRoleId(token, role), holder));
        }
        console.log(unicode"✅ Role revoked successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Token Role Revoked on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token:  ", helperConfig.getExplorerUrl(chainId, "/address/", token)));
        console.log(string.concat("Role:   ", RolesProbes.tokenRoleName(role)));
        console.log(string.concat("Holder: ", vm.toString(holder)));
        console.log("========================================");
        console.log("");
    }

    /// @dev Virtual input seams (like `_executionMode`): the env vars are process-wide, so tests pin
    ///      inputs via overrides instead of `vm.setEnv` (which would race parallel suites).
    function _roleName() internal view virtual returns (string memory) {
        return vm.envString("ROLE");
    }

    function _holder() internal view virtual returns (address) {
        return vm.envOr("HOLDER", address(0));
    }
}
