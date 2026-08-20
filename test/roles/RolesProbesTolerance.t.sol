// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RolesProbes} from "../../src/roles/RolesProbes.sol";
import {ArrayLengthOverflowsWordSize, ArrayLengthOverrunsBody, EmptyReturn} from "../fixtures/ReturnDataShells.sol";

/// @notice `_tryAddressArray` reads `address[]` getters off contracts the operator named, so it meets
/// the same hostile answers the string readers do - see `src/utils/TolerantCall.sol`. Its own
/// `ret.length >= 64` check passed a header claiming more entries than the body holds. The probe is an
/// internal library, so the decode runs inline in whatever called it and no `try` at the call site can
/// catch it.
contract RolesProbesToleranceTest is Test {
    function test_ArrayHeaderOverrunningItsBody_ReadsEmpty() public {
        (bool ok, address[] memory vals) = RolesProbes._tryAddressArray(
            address(new ArrayLengthOverrunsBody()), abi.encodeWithSignature("getAllAuthorizedCallers()")
        );
        assertFalse(ok, "a length the body cannot hold must be rejected before decoding");
        assertEq(vals.length, 0, "and yields no entries");
    }

    /// A length large enough that multiplying it by the element size overflows. Rejected before the
    /// multiplication, because the multiplication itself would panic where nothing can catch it.
    function test_ArrayLengthOverflowingWordSize_ReadsEmpty() public {
        (bool ok, address[] memory vals) = RolesProbes._tryAddressArray(
            address(new ArrayLengthOverflowsWordSize()), abi.encodeWithSignature("getAllAuthorizedCallers()")
        );
        assertFalse(ok, "a length that cannot be multiplied by the element size must be rejected");
        assertEq(vals.length, 0, "and yields no entries");
    }

    function test_EmptyAnswer_ReadsEmpty() public {
        (bool ok, address[] memory vals) = RolesProbes._tryAddressArray(
            address(new EmptyReturn()), abi.encodeWithSignature("getAllAuthorizedCallers()")
        );
        assertFalse(ok, "success with no data is not an array");
        assertEq(vals.length, 0, "and yields no entries");
    }

    function test_CodelessAddress_ReadsEmpty() public view {
        (bool ok,) = RolesProbes._tryAddressArray(address(0xdead), abi.encodeWithSignature("getAllAuthorizedCallers()"));
        assertFalse(ok, "no code cannot answer");
    }
}
