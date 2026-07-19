// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {TokenRoleScript} from "./TokenRoleScript.s.sol";
import {RolesProbes} from "../../../src/roles/RolesProbes.sol";

/**
 * @notice Grants a token role (minter / burner / burnMintAdmin) to a holder, template-dispatched:
 *         AccessControl templates (`crosschain`, `burnmint`) get `grantRole` with the token's resolved
 *         role id; the Ownable `factory` template gets `grantMintRole`/`grantBurnRole`. A role the
 *         detected template does not carry is refused by name BEFORE any state-changing call
 *         (`RolesProbes.requireRoleOnTemplate`) — a naive `grantRole` with the fallback id would
 *         succeed on-chain and move nothing. BYO tokens are refused (token-internal roles are not
 *         movable through the primitives).
 *
 * Required env vars:
 *   ROLE    — one of: minter, burner, burnMintAdmin, defaultAdmin (burnMintAdmin exists only on
 *             crosschain; defaultAdmin only on burnmint — the grant-model multi-holder admin)
 *
 * Optional env vars:
 *   TOKEN   — token address (defaults to the {CHAIN}_TOKEN / registry resolution ladder)
 *   HOLDER  — the grant recipient (defaults to the executing account: the Safe in MODE=safe)
 *
 * Usage:
 *   ROLE=minter HOLDER=0xRecipient \
 *     forge script script/setup/token-roles/GrantTokenRole.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract GrantTokenRole is TokenRoleScript {
    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address token = _resolveToken(config, chainId);

        RolesProbes.TokenRole role = RolesProbes.tokenRoleFromName(_roleName());
        RolesProbes.TokenTemplate template = RolesProbes.detectTemplate(token);
        RolesProbes.requireRoleOnTemplate(template, role);

        address actor = executingAccount();
        address holder = _holder(actor);
        require(holder != address(0), "HOLDER must be a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(unicode"🔑 Grant Token Role");
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

        console.log(string.concat("\n[Step 1] Granting ", RolesProbes.tokenRoleName(role), " on ", chainName));
        if (template == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            // Only Minter/Burner reach this branch (requireRoleOnTemplate refused the admin roles on
            // factory); the explicit check keeps a future role from silently mapping to grantBurnRole.
            if (role == RolesProbes.TokenRole.Minter) {
                executeCalls(CctActions.grantMintRole(token, holder));
            } else {
                require(role == RolesProbes.TokenRole.Burner, "factory tokens carry only minter/burner roles");
                executeCalls(CctActions.grantBurnRole(token, holder));
            }
        } else {
            executeCalls(CctActions.grantRole(token, RolesProbes.tokenRoleId(token, role), holder));
        }
        console.log(unicode"✅ Role granted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Token Role Granted on ", chainName, "!"));
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

    function _holder(address defaultHolder) internal view virtual returns (address) {
        return vm.envOr("HOLDER", defaultHolder);
    }
}
