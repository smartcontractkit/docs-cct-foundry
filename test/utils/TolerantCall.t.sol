// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TolerantCall} from "../../src/utils/TolerantCall.sol";
import {
    BareStringRevert,
    EmptyReturn,
    LengthOverrunsBody,
    RealTypeAndVersion,
    ShortWord,
    WildOffset
} from "../fixtures/ReturnDataShells.sol";

interface ITypeAndVersionLike {
    function typeAndVersion() external view returns (string memory);
}

/// @notice `_tryString` against the answers that defeat `try ... returns (string)`.
///
/// Four shapes are chosen so that exactly one check rejects each: `ShortWord` (minimum size),
/// `WildOffset` (canonical offset), `LengthOverrunsBody` (body bounds), `BareStringRevert` (the call
/// failed). Those four fail when their own check alone is broken.
///
/// `EmptyReturn` and the codeless case pin no single check - either is caught by another if its own is
/// removed. They are here because they are the shapes real contracts produce.
contract TolerantCallTest is Test {
    function test_RealGetter_IsRead() public {
        (bool ok, string memory v) = TolerantCall._tryString(address(new RealTypeAndVersion()), "typeAndVersion()");
        assertTrue(ok, "a contract that answers must be read");
        assertEq(v, "BurnMintTokenPool 1.5.1", "and its answer returned verbatim");
    }

    function test_CodelessAddress_IsUnreadable() public view {
        (bool ok,) = TolerantCall._tryString(address(0xdead), "typeAndVersion()");
        assertFalse(ok, "no code cannot answer");
    }

    /// The motivating shape: success with no data, which is what a Safe with no fallback handler and a
    /// clone over a codeless implementation both return.
    function test_EmptyReturn_IsUnreadable() public {
        (bool ok, string memory v) = TolerantCall._tryString(address(new EmptyReturn()), "typeAndVersion()");
        assertFalse(ok, "success with no data is not an answer");
        assertEq(v, "", "and yields no value");
    }

    /// Pins the minimum-size check. Drop it and this input reaches `ret.length - 64`, which underflows
    /// and panics - a failure no catch can reach, the class this library exists to prevent.
    function test_OneWordAnswer_IsUnreadable() public {
        (bool ok,) = TolerantCall._tryString(address(new ShortWord()), "typeAndVersion()");
        assertFalse(ok, "32 bytes cannot hold an offset and a length");
    }

    /// Pins the canonical-offset check: the length word here is 0, so the bounds check is satisfied and
    /// only the offset check can reject it.
    function test_NonCanonicalOffset_IsUnreadable() public {
        (bool ok,) = TolerantCall._tryString(address(new WildOffset()), "typeAndVersion()");
        assertFalse(ok, "an offset that is not 32 must be rejected before decoding");
    }

    /// Pins the bounds check at its exact boundary: 64 bytes returned, 32 claimed, so the body is one
    /// word short. A loose check (`length <= ret.length`) accepts this and the decode reverts.
    function test_LengthOverrunsBody_IsUnreadable() public {
        (bool ok,) = TolerantCall._tryString(address(new LengthOverrunsBody()), "typeAndVersion()");
        assertFalse(ok, "a length the returned data cannot hold must be rejected");
    }

    /// Pins the `success` check. The revert payload IS a valid ABI string, so every structural check
    /// passes; only the call's failure distinguishes it.
    function test_RevertCarryingAValidString_IsUnreadable() public {
        (bool ok, string memory v) = TolerantCall._tryString(address(new BareStringRevert()), "typeAndVersion()");
        assertFalse(ok, "a revert is not an answer, whatever it carries");
        assertEq(v, "", "and its payload must not be returned");
    }

    /// The same contract through a plain `try` reverts the frame; the helper returns.
    function test_APlainTryDiesOnTheSameContract() public {
        address shell = address(new EmptyReturn());
        (bool ok,) = TolerantCall._tryString(shell, "typeAndVersion()");
        assertFalse(ok, "the helper survives it");
        vm.expectRevert();
        this.plainTry(shell);
    }

    function plainTry(address target) external view returns (string memory) {
        try ITypeAndVersionLike(target).typeAndVersion() returns (string memory s) {
            return s;
        } catch {
            return "caught";
        }
    }
}
