// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {HelperConfig} from "../../HelperConfig.s.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {RolesProbes} from "../../../src/roles/RolesProbes.sol";

/// @notice Shared base for the token-role scripts (`GrantTokenRole`, `RevokeTokenRole`, `SetCCIPAdmin`,
///         `TransferTokenAdmin`): the token-resolution seam and the role-admin authority preflight live
///         here once instead of being copied into each script.
abstract contract TokenRoleScript is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev Virtual input seam (like `_executionMode`): the env vars are process-wide, so tests pin the
    ///      token via an override instead of `vm.setEnv` (which would race parallel suites).
    function _resolveToken(HelperConfig.NetworkConfig memory config, uint256 chainId)
        internal
        virtual
        returns (address token)
    {
        token = helperConfig.getDeployedToken(chainId);
        require(
            token != address(0),
            string.concat(
                "Token not deployed. Set TOKEN or ", config.chainNameIdentifier, "_TOKEN environment variable."
            )
        );
    }

    /// @dev The account allowed to move a token role, per template: the factory owner; the crosschain
    ///      `BURN_MINT_ADMIN_ROLE` holder for mint/burn and `DEFAULT_ADMIN_ROLE` for burnMintAdmin
    ///      itself; a burnmint `DEFAULT_ADMIN_ROLE` holder. Compared against the EXECUTING account (the
    ///      Safe in safe mode), never the broadcaster. OZ AccessControl gates grant and revoke with the
    ///      same admin role, and the factory set is owner-gated both ways, so grant and revoke share this.
    function requireTokenRoleAuthority(
        address token,
        RolesProbes.TokenTemplate template,
        RolesProbes.TokenRole role,
        address actor
    ) internal view {
        if (template == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            (, address owner_) = RolesProbes.tryAddress(token, "owner()");
            require(
                owner_ == actor,
                string.concat(
                    "Executing account (", vm.toString(actor), ") is not the token owner (", vm.toString(owner_), ")."
                )
            );
            return;
        }
        bytes32 adminRole = (template == RolesProbes.TokenTemplate.CrossChainToken
                && role != RolesProbes.TokenRole.BurnMintAdmin)
            ? RolesProbes.roleIdOrDefault(token, "BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE)
            : RolesProbes.DEFAULT_ADMIN_ROLE;
        require(
            RolesProbes.hasRole(token, adminRole, actor),
            string.concat(
                "Executing account (", vm.toString(actor), ") does not hold the role-admin role on this token."
            )
        );
    }
}
