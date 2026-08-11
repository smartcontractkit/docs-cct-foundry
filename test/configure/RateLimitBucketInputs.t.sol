// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RateLimiterUtils} from "../../script/utils/RateLimiterUtils.s.sol";

/// @notice What a rate-limit bucket accepts as input, all-or-nothing per direction.
///
/// An unset variable must never become a 0 written on chain; the failure modes that rule prevents are
/// documented on `RateLimiterUtils._establishBucket`, the single decision every consumer routes
/// through. The decision is
/// pinned through `_establishBucket`, which takes the set-flags and values as arguments: `vm.setEnv` is
/// process-wide while tests run in parallel, and the apply scripts read the same variables, so these
/// tests never touch the environment.
contract RateLimitBucketInputsTest is Test {
    function test_NothingSet_LeavesTheDirectionUntouched() public pure {
        (bool update,,,) = RateLimiterUtils._establishBucket("OUTBOUND", false, false, false, 0, false, 0);
        assertFalse(update);
    }

    function test_FullBucket_Applies() public pure {
        (bool update, bool enabled, uint128 capacity, uint128 rate) =
            RateLimiterUtils._establishBucket("OUTBOUND", true, true, true, 1000, true, 10);
        assertTrue(update);
        assertTrue(enabled);
        assertEq(capacity, 1000);
        assertEq(rate, 10);
    }

    function test_CapacityAndRate_ImplyEnabled() public pure {
        // enabled=false here is deliberately ignorable: with enabledSet=false the helper computes the
        // implied default itself, so a consumer cannot wire it differently.
        (bool update, bool enabled, uint128 capacity, uint128 rate) =
            RateLimiterUtils._establishBucket("INBOUND", false, false, true, 500, true, 5);
        assertTrue(update);
        assertTrue(enabled, "supplying capacity and rate implies enabling the bucket");
        assertEq(capacity, 500);
        assertEq(rate, 5);
    }

    /// @dev The incident-response shape: an explicit disable stands alone. A disabled bucket's
    ///      capacity and rate are 0 by protocol rule, so the zeros are forced, not guessed.
    function test_DisableAlone_IsValid() public pure {
        (bool update, bool enabled, uint128 capacity, uint128 rate) =
            RateLimiterUtils._establishBucket("OUTBOUND", true, false, false, 0, false, 0);
        assertTrue(update);
        assertFalse(enabled);
        assertEq(capacity, 0);
        assertEq(rate, 0);
    }

    function test_DisableWithNonZeroCapacity_Refuses() public {
        vm.expectRevert(
            bytes(
                "OUTBOUND: a disabled rate-limit bucket has capacity 0 and rate 0 by protocol rule - drop the"
                " CAPACITY/RATE variables or set OUTBOUND_RATE_LIMIT_ENABLED=true"
            )
        );
        this.establish("OUTBOUND", true, false, true, 7, false, 0);
    }

    function test_CapacityAlone_RefusesNamingRate() public {
        vm.expectRevert(
            bytes(
                "OUTBOUND_RATE_LIMIT_RATE is not set - an enabled bucket needs CAPACITY and RATE supplied"
                " together; an unset field must not become a 0 written on chain"
            )
        );
        this.establish("OUTBOUND", false, false, true, 1000, false, 0);
    }

    function test_RateAlone_RefusesNamingCapacity() public {
        vm.expectRevert(
            bytes(
                "INBOUND_RATE_LIMIT_CAPACITY is not set - an enabled bucket needs CAPACITY and RATE supplied"
                " together; an unset field must not become a 0 written on chain"
            )
        );
        this.establish("INBOUND", false, false, false, 0, true, 10);
    }

    function test_EnabledAlone_RefusesNamingCapacity() public {
        vm.expectRevert(
            bytes(
                "OUTBOUND_RATE_LIMIT_CAPACITY is not set - an enabled bucket needs CAPACITY and RATE supplied"
                " together; an unset field must not become a 0 written on chain"
            )
        );
        this.establish("OUTBOUND", true, true, false, 0, false, 0);
    }

    /// @dev 1e39 wraps to a plausible wrong capacity under a raw uint128 cast; 2^128 wraps to exactly
    ///      0. Both are refused instead of becoming a different live value.
    function test_Overflow_RefusesInsteadOfTruncating() public {
        vm.expectRevert(
            bytes(
                "OUTBOUND_RATE_LIMIT_CAPACITY does not fit uint128 - refusing to truncate it into a different live value"
            )
        );
        this.establish("OUTBOUND", false, false, true, 1e39, true, 10);

        vm.expectRevert(
            bytes("INBOUND_RATE_LIMIT_RATE does not fit uint128 - refusing to truncate it into a different live value")
        );
        this.establish("INBOUND", false, false, true, 1000, true, 2 ** 128);
    }

    /// @notice External for `expectRevert`: an internal library call would revert the test itself.
    function establish(
        string memory direction,
        bool enabledSet,
        bool enabled,
        bool capacitySet,
        uint256 capacity,
        bool rateSet,
        uint256 rate
    ) external pure returns (bool, bool, uint128, uint128) {
        return RateLimiterUtils._establishBucket(direction, enabledSet, enabled, capacitySet, capacity, rateSet, rate);
    }
}
