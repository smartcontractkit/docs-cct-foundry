// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {IsAllowListed} from "../../script/configure/allowlist/IsAllowListed.s.sol";

/// @dev Hooks whose `checkAllowList` reverts with the MEMBERSHIP answer. Enforcement on, sender out.
contract MockHooksNotAllowed {
    function getAllowListEnabled() external pure returns (bool) {
        return true;
    }

    function checkAllowList(address sender) external pure {
        revert AdvancedPoolHooks.SenderNotAllowed(sender);
    }
}

/// @dev Hooks whose `checkAllowList` reverts for a reason that is NOT a membership answer. This is
///      what an out-of-gas, a proxy reverting for its own reasons, or an RPC-level failure looks like
///      from the caller's side: a revert carrying something other than SenderNotAllowed.
contract MockHooksUnreadable {
    error SomethingElse();

    function getAllowListEnabled() external pure returns (bool) {
        return true;
    }

    function checkAllowList(address) external pure {
        revert SomethingElse();
    }
}

/// @dev Hooks whose `checkAllowList` reverts with NO data at all - a bare `revert()`, which is also
///      what a callee out-of-gas looks like to the caller. This is the case where the selector match
///      could plausibly go wrong: `bytes4` of empty `bytes` zero-pads to 0x00000000, so it must not
///      be mistaken for SenderNotAllowed (0xd0d25976).
contract MockHooksEmptyRevert {
    function getAllowListEnabled() external pure returns (bool) {
        return true;
    }

    function checkAllowList(address) external pure {
        revert();
    }
}

/// @notice "Not allowlisted" must come from the allowlist, never from a read that failed.
///
/// @dev The script used a bare `catch {}`, so ANY revert became a confident
///      "Address is NOT allowlisted" - a definite negative verdict derived from a call that never
///      answered. That is the failure this repo has already fixed twice elsewhere (silent
///      substitution; report only what was observed), and the sibling `getAllowListEnabled()` catch
///      twenty lines above reverts precisely to avoid it. The linter cannot see this one because the
///      variable is explicitly initialised, so it needs a test rather than a lint rule.
contract IsAllowListedReadFailureTest is Test {
    IsAllowListed internal script;
    address internal constant SENDER = address(0xBEEF);
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    function setUp() public {
        // No fork needed: nothing here reads chain state. The id only has to be one HelperConfig
        // recognises, so the script gets past its network lookup and reaches the allowlist read.
        vm.chainId(SEPOLIA_CHAIN_ID);
        script = new IsAllowListed();
        vm.setEnv("CHECK_ADDRESS", vm.toString(SENDER));
    }

    /// A real SenderNotAllowed IS the answer: the script reports it and exits cleanly.
    function test_senderNotAllowed_isAVerdict() public {
        vm.setEnv("POOL_HOOKS", vm.toString(address(new MockHooksNotAllowed())));
        script.run();
    }

    /// A revert with EMPTY data is not an answer either. bytes4("") is 0x00000000, which must not be
    /// read as a selector match - an out-of-gas would otherwise report a definite "not allowlisted".
    function test_emptyRevertData_refusesRatherThanMatchingASelector() public {
        vm.setEnv("POOL_HOOKS", vm.toString(address(new MockHooksEmptyRevert())));
        vm.expectRevert(bytes("checkAllowList() did not answer - membership is UNKNOWN, not negative"));
        script.run();
    }

    /// Any other revert is NOT an answer, and must not be reported as one.
    function test_unreadableCheck_refusesRatherThanReportingNotAllowlisted() public {
        vm.setEnv("POOL_HOOKS", vm.toString(address(new MockHooksUnreadable())));
        vm.expectRevert(bytes("checkAllowList() did not answer - membership is UNKNOWN, not negative"));
        script.run();
    }
}
