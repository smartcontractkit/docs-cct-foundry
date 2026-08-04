// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Helpers for interpreting encoded address bytes in read-only scripts.
library AddressEncoding {
    /// @dev True when `data` is a canonical ABI-encoded EVM address: a 32-byte word
    ///      with the high 12 bytes zero.
    function _isAbiEncodedAddress(bytes memory data) internal pure returns (bool) {
        if (data.length != 32) return false;
        for (uint256 i = 0; i < 12; i++) {
            if (data[i] != 0) return false;
        }
        return true;
    }
}
