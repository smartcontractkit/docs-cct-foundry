// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TokenRoleScript} from "../../script/setup/token-roles/TokenRoleScript.s.sol";
import {RolesProbes} from "../../src/roles/RolesProbes.sol";

/// @dev A token that has code and answers nothing: the shape a wrong or unreadable TOKEN address
///      takes when an authority preflight probes it.
contract SilentToken {
    fallback() external {
        revert("silent");
    }
}

contract TokenRoleGateHarness is TokenRoleScript {
    function requireAuthority(
        address token,
        RolesProbes.TokenTemplate template,
        RolesProbes.TokenRole role,
        address actor
    ) external view {
        _requireTokenRoleAuthority(token, template, role, actor);
    }
}

/// @notice The authority preflight refuses a failed read BEFORE the equality check. Without the gate,
/// a token whose `owner()` does not answer reads as owner `0x0`, and the refusal message would
/// attribute that owner to a token nobody observed.
contract TokenRoleAuthorityGatesTest is Test {
    TokenRoleGateHarness internal harness;
    address internal silent;

    function setUp() public {
        harness = new TokenRoleGateHarness();
        silent = address(new SilentToken());
    }

    function test_FactoryGate_RefusesAFailedOwnerRead() public {
        vm.expectRevert(bytes("owner() could not be read from the token, so authority cannot be verified"));
        harness.requireAuthority(
            silent, RolesProbes.TokenTemplate.FactoryBurnMintERC20, RolesProbes.TokenRole.Minter, address(0xBEEF)
        );
    }
}
