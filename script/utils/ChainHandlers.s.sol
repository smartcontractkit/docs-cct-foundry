// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ChainHandlers
/// @notice Address validation and encoding utilities for EVM and SVM (Solana)
///         destination chains. Mirrors the TypeScript chainHandlers.ts utility in the Hardhat project.
///
/// @dev prepareChainAddressData output format (for use in TokenPool.ChainUpdate):
///   EVM   → abi.encode(address)  - 32-byte ABI-padded word
///   SVM   → raw 32 bytes         - base58-decoded Solana public key
///
/// Typical usage in ApplyChainUpdates.s.sol:
///   string memory destChainFamily = vm.envOr("DEST_CHAIN_FAMILY", string("evm"));
///   ChainHandlers.ChainFamily family = ChainHandlers._parseChainFamily(destChainFamily);
///
///   string memory destPoolStr   = vm.envString("DEST_TOKEN_POOL");
///   string memory destTokenStr  = vm.envString("DEST_TOKEN");
///
///   bytes memory encodedPool  = ChainHandlers._prepareChainAddressData(destPoolStr,  family);
///   bytes memory encodedToken = ChainHandlers._prepareChainAddressData(destTokenStr, family);
library ChainHandlers {
    // ─── Types ───────────────────────────────────────────────────────────────

    /// @notice Supported destination chain families.
    enum ChainFamily {
        EVM,
        SVM
    }

    // ─── Errors ──────────────────────────────────────────────────────────────

    /// @notice Thrown when an address string is not valid for its declared chain family.
    error InvalidChainAddress(string addr, string chainFamily);

    // ─── Public API ──────────────────────────────────────────────────────────

    /// @notice Returns true if `addr` is a syntactically valid address for `family`.
    /// @dev EVM   - "0x" prefix + exactly 40 hex characters.
    ///      SVM   - base58 characters only, 32-44 chars long, decodes to exactly 32 bytes.
    function _validateChainAddress(string memory addr, ChainFamily family) internal pure returns (bool) {
        if (family == ChainFamily.EVM) return _isValidEvmAddress(addr);
        if (family == ChainFamily.SVM) return _isValidSvmAddress(addr);
        return false;
    }

    /// @notice Encodes `addr` into the byte format expected by TokenPool.ChainUpdate
    ///         (remotePoolAddresses[] entries and remoteTokenAddress).
    ///   EVM   → abi.encode(address)   - 32-byte ABI word
    ///   SVM   → 32 raw bytes           - base58-decoded Solana public key
    /// @dev Reverts with InvalidChainAddress if the address is malformed for the given family.
    function _prepareChainAddressData(string memory addr, ChainFamily family) internal pure returns (bytes memory) {
        if (family == ChainFamily.EVM) return _prepareEvmAddress(addr);
        if (family == ChainFamily.SVM) return _prepareSvmAddress(addr);
        revert("ChainHandlers: unsupported chain family");
    }

    /// @notice Parses a chain family string into the ChainFamily enum.
    ///         Accepts lowercase and uppercase: "evm"/"EVM", "svm"/"SVM",
    ///         "solana"/"SOLANA" (alias for SVM).
    function _parseChainFamily(string memory familyStr) internal pure returns (ChainFamily) {
        bytes32 h = keccak256(bytes(familyStr));
        if (h == keccak256("evm") || h == keccak256("EVM")) return ChainFamily.EVM;
        if (h == keccak256("svm") || h == keccak256("SVM") || h == keccak256("solana") || h == keccak256("SOLANA")) {
            return ChainFamily.SVM;
        }
        revert("ChainHandlers: unsupported chain family string");
    }

    // ─── EVM ─────────────────────────────────────────────────────────────────

    function _isValidEvmAddress(string memory addr) private pure returns (bool) {
        bytes memory b = bytes(addr);
        if (b.length != 42) return false;
        if (b[0] != "0" || b[1] != "x") return false;
        for (uint256 i = 2; i < 42; i++) {
            if (!_isHexChar(b[i])) return false;
        }
        return true;
    }

    /// @dev Parses a "0x"-prefixed 20-byte hex address string and returns abi.encode(address).
    function _prepareEvmAddress(string memory addr) private pure returns (bytes memory) {
        if (!_isValidEvmAddress(addr)) revert InvalidChainAddress(addr, "evm");
        bytes memory b = bytes(addr);
        uint160 parsed = 0;
        for (uint256 i = 2; i < 42; i++) {
            parsed = parsed * 16 + uint160(_hexCharToByte(b[i]));
        }
        return abi.encode(address(parsed));
    }

    // ─── SVM (Solana) ────────────────────────────────────────────────────────

    function _isValidSvmAddress(string memory addr) private pure returns (bool) {
        bytes memory b = bytes(addr);
        // Solana public keys (32 bytes) base58-encode to 43 or 44 characters.
        if (b.length < 32 || b.length > 44) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (_base58CharValue(b[i]) == type(uint8).max) return false;
        }
        // Fully decode and confirm the output is exactly 32 bytes.
        bytes memory decoded = _decodeBase58(b);
        return decoded.length == 32;
    }

    /// @dev Base58-decodes a Solana public key string and returns the raw 32 bytes.
    function _prepareSvmAddress(string memory addr) private pure returns (bytes memory) {
        bytes memory b = bytes(addr);
        if (b.length < 32 || b.length > 44) revert InvalidChainAddress(addr, "svm");
        bytes memory decoded = _decodeBase58(b);
        if (decoded.length != 32) revert InvalidChainAddress(addr, "svm");
        return decoded;
    }

    // ─── Base58 decoder ──────────────────────────────────────────────────────

    /// @dev Decodes a base58-encoded byte array into raw bytes (big-endian, no checksum).
    ///      Uses a uint256[] working buffer; safe for inputs up to 44 characters (Solana keys).
    ///
    ///      Algorithm:
    ///        1. Count leading '1' characters → each maps to a leading 0x00 byte.
    ///        2. Treat the remaining characters as a base-58 number and convert to base-256
    ///           using a byte-array accumulator (schoolbook long multiplication).
    ///        3. Strip buffer padding zeros, then re-prepend the leading zero bytes.
    function _decodeBase58(bytes memory input) private pure returns (bytes memory) {
        uint256 len = input.length;

        // Count leading '1's - ASCII 0x31 - each represents a leading 0x00 byte.
        uint256 leadingZeros = 0;
        for (uint256 i = 0; i < len; i++) {
            if (input[i] == 0x31) {
                leadingZeros++;
            } else {
                break;
            }
        }

        // Working buffer size: upper bound on output byte count.
        // log(58) / log(256) ≈ 0.7325; multiply by 10000 to stay in integer arithmetic.
        // For 44 input chars → (44 * 7325) / 10000 + 1 = 33 slots (covers 32-byte Solana keys).
        uint256 bufLen = (len * 7325) / 10000 + 1;
        uint256[] memory buf = new uint256[](bufLen);

        for (uint256 i = 0; i < len; i++) {
            uint8 charVal = _base58CharValue(input[i]);
            require(charVal != type(uint8).max, "ChainHandlers: invalid base58 character");
            uint256 carry = charVal;
            for (uint256 j = bufLen; j > 0; j--) {
                carry += 58 * buf[j - 1];
                buf[j - 1] = carry % 256;
                carry /= 256;
            }
        }

        // Skip buffer padding zeros (distinct from leading-zero bytes above).
        uint256 skip = 0;
        while (skip < bufLen && buf[skip] == 0) {
            skip++;
        }

        // Assemble: leadingZeros zero-bytes followed by the significant bytes.
        uint256 sigLen = bufLen - skip;
        bytes memory result = new bytes(leadingZeros + sigLen);
        for (uint256 i = 0; i < sigLen; i++) {
            result[leadingZeros + i] = bytes1(uint8(buf[skip + i]));
        }
        return result;
    }

    /// @dev Returns the numeric value (0–57) of a base58 alphabet character,
    ///      or type(uint8).max (255) for characters not in the alphabet.
    ///
    ///      Alphabet: 123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz
    ///      Absent: 0 (zero), I (capital i), O (capital o), l (lowercase L).
    function _base58CharValue(bytes1 c) private pure returns (uint8) {
        uint8 ch = uint8(c);
        if (ch >= 49 && ch <= 57) return ch - 49; // '1'-'9' →  0- 8
        if (ch >= 65 && ch <= 72) return ch - 56; // 'A'-'H' →  9-16
        if (ch >= 74 && ch <= 78) return ch - 57; // 'J'-'N' → 17-21  (skip 'I')
        if (ch >= 80 && ch <= 90) return ch - 58; // 'P'-'Z' → 22-32  (skip 'O')
        if (ch >= 97 && ch <= 107) return ch - 64; // 'a'-'k' → 33-43
        if (ch >= 109 && ch <= 122) return ch - 65; // 'm'-'z' → 44-57  (skip 'l')
        return type(uint8).max; // not in alphabet
    }

    // ─── Base58 encoder ───────────────────────────────────────────────────────

    /// @notice Encodes raw bytes (e.g. a 32-byte Solana public key) as a base58 string.
    ///         Useful for displaying SVM addresses returned by TokenPool.getRemotePools.
    ///
    ///      Algorithm (reverse of _decodeBase58):
    ///        1. Count leading 0x00 bytes → each maps to a leading '1' character.
    ///        2. Treat the remaining bytes as a base-256 number and convert to base-58
    ///           using a byte-array accumulator (schoolbook long division).
    ///        3. Reverse the accumulated digits and prepend the leading '1' characters.
    function _encodeBase58(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

        // Count leading zero bytes.
        uint256 leadingZeros = 0;
        for (uint256 i = 0; i < data.length && data[i] == 0; i++) {
            leadingZeros++;
        }

        // Upper bound on output length: log(256)/log(58) ≈ 1.365 per input byte.
        // For 32 bytes → ceil(32 * 13650 / 10000) + 1 = 44 slots (exact for Solana keys).
        uint256 bufLen = (data.length * 13650) / 10000 + 2;
        bytes memory digits = new bytes(bufLen);
        uint256 digitsUsed = 0;

        for (uint256 i = 0; i < data.length; i++) {
            uint256 carry = uint8(data[i]);
            for (uint256 j = 0; j < digitsUsed; j++) {
                carry += uint256(uint8(digits[j])) * 256;
                digits[j] = bytes1(uint8(carry % 58));
                carry /= 58;
            }
            while (carry > 0) {
                digits[digitsUsed++] = bytes1(uint8(carry % 58));
                carry /= 58;
            }
        }

        // Assemble: leading '1' characters + reversed digits mapped through alphabet.
        bytes memory result = new bytes(leadingZeros + digitsUsed);
        for (uint256 i = 0; i < leadingZeros; i++) {
            result[i] = alphabet[0]; // '1'
        }
        for (uint256 i = 0; i < digitsUsed; i++) {
            result[leadingZeros + i] = alphabet[uint8(digits[digitsUsed - 1 - i])];
        }
        return string(result);
    }

    // ─── Shared hex helpers ──────────────────────────────────────────────────

    function _isHexChar(bytes1 c) private pure returns (bool) {
        uint8 ch = uint8(c);
        return (ch >= 48 && ch <= 57) // '0'-'9'
            || (ch >= 65 && ch <= 70) // 'A'-'F'
            || (ch >= 97 && ch <= 102); // 'a'-'f'
    }

    function _hexCharToByte(bytes1 c) private pure returns (uint8) {
        uint8 ch = uint8(c);
        if (ch >= 48 && ch <= 57) return ch - 48; // '0'-'9' → 0-9
        if (ch >= 65 && ch <= 70) return ch - 55; // 'A'-'F' → 10-15
        if (ch >= 97 && ch <= 102) return ch - 87; // 'a'-'f' → 10-15
        revert("ChainHandlers: invalid hex char");
    }
}
