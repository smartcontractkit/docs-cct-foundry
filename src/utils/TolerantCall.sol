// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title TolerantCall
/// @notice Reads a `string` getter off an address that may not implement it, without ever reverting.
/// @dev Not a `try`. `try C(a).f() returns (string memory)` routes a REVERT to its catch, but the
///      return data is decoded in the CALLER's frame after the call already succeeded, so an address
///      that answers successfully with bytes that are not a valid ABI `string` reverts outside the
///      catch and the message names no read.
///
///      Two halves. A codeless address answers with empty data. An address WITH code can answer just
///      as undecodably: a Safe with no fallback handler set, an EIP-1167 clone over a codeless
///      implementation, or a proxy whose catch-all fallback returns rather than reverts. All three
///      produce the same shape - success with no data - which `test/fixtures/ReturnDataShells.sol`
///      reproduces as `EmptyReturn`. A `code.length` guard covers only the first half.
///
///      The return data is therefore validated before `abi.decode` touches it.
library TolerantCall {
    /// @notice Calls `signature` on `target` and returns its string result. `ok` is false - never a
    ///         revert - when the address holds no code, the call fails, or the answer is not a
    ///         decodable ABI string. Callers decide what an unreadable answer means.
    function _tryString(address target, string memory signature) internal view returns (bool ok, string memory value) {
        if (target.code.length == 0) return (false, "");
        (bool success, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (!success || !_decodesAsDynamic(ret, 1)) return (false, "");
        return (true, abi.decode(ret, (string)));
    }

    /// @notice Whether `ret` holds a canonically-encoded dynamic value whose body fits: a 32-byte
    ///         offset word, a 32-byte length word, then `length * elementSize` bytes that the returned
    ///         data can actually hold. `elementSize` is 1 for a `string`/`bytes` and 32 for an array of
    ///         words. This is STRICTER than `abi.decode`, which accepts any in-bounds offset: solc only
    ///         ever emits 32, and treating anything else as unreadable costs a caller nothing while
    ///         keeping the check trivial to verify.
    /// @dev `elementSize` must be non-zero. Bounds the BODY, not the elements: a decoder validator
    ///      (`address`, `bool`) can still reject a word and revert in the caller's frame.
    function _decodesAsDynamic(bytes memory ret, uint256 elementSize) internal pure returns (bool) {
        if (ret.length < 64) return false; // no room for the offset and length words
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(ret, 32))
            length := mload(add(ret, 64))
        }
        if (offset != 32) return false;
        if (length > type(uint256).max / elementSize) return false; // body size would overflow
        return length * elementSize <= ret.length - 64;
    }
}
