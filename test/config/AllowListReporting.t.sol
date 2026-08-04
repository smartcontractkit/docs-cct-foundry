// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";

/// @notice What `checkAllowList` can and cannot tell a caller about an address.
///
/// The call is a no-op while the allowlist is disabled: it returns without reverting for every address,
/// `0x0` included. A non-revert therefore carries a membership answer only once enforcement is known to
/// be on, and any report built on it has to establish that first. These tests pin the distinction.
contract AllowListReportingTest is Test {
    address internal constant MEMBER = address(0xA11CE);
    address internal constant STRANGER = address(0xB0B);

    function _hooks(address[] memory allowlist) private returns (AdvancedPoolHooks) {
        return new AdvancedPoolHooks(allowlist, 0, address(0), new address[](0));
    }

    /// @dev The disabled case. `i_allowlistEnabled` is `allowlist.length > 0` and immutable, so hooks
    ///      deployed with no allowlist can never enforce one, and the check passes for anybody.
    function test_CheckAllowList_IsNoOpWhileDisabled() public {
        AdvancedPoolHooks hooks = _hooks(new address[](0));

        assertFalse(hooks.getAllowListEnabled(), "an empty allowlist leaves enforcement off");

        // Neither call means "this address is permitted": nothing is being checked at all.
        hooks.checkAllowList(STRANGER);
        hooks.checkAllowList(address(0));
    }

    /// @dev The enabled case, which is the only one where a non-revert carries information.
    function test_CheckAllowList_EnforcesMembershipWhileEnabled() public {
        address[] memory allowlist = new address[](1);
        allowlist[0] = MEMBER;
        AdvancedPoolHooks hooks = _hooks(allowlist);

        assertTrue(hooks.getAllowListEnabled(), "a non-empty allowlist enables enforcement");

        hooks.checkAllowList(MEMBER);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAllowed(address)", STRANGER));
        hooks.checkAllowList(STRANGER);
    }

    /// @dev Both states are reachable from the constructor, so a report that does not name which one it
    ///      observed cannot be acted on: the same "permitted" verdict means everything or nothing.
    function test_AllowListState_OnlyGetAllowListEnabledSeparatesTheTwoStates() public {
        AdvancedPoolHooks disabled = _hooks(new address[](0));
        address[] memory allowlist = new address[](1);
        allowlist[0] = STRANGER;
        AdvancedPoolHooks enabled = _hooks(allowlist);

        // checkAllowList answers identically for STRANGER in both, though only one permits it.
        disabled.checkAllowList(STRANGER);
        enabled.checkAllowList(STRANGER);

        assertFalse(disabled.getAllowListEnabled(), "disabled");
        assertTrue(enabled.getAllowListEnabled(), "enabled");
    }
}
