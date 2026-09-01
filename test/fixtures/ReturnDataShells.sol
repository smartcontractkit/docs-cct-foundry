// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Contracts that ANSWER a call with bytes that are not a decodable ABI string - see
/// `src/utils/TolerantCall.sol` for why a successful call can still revert.
///
/// Most shapes here are chosen to be rejected by exactly ONE of that library's checks, so a test using
/// one fails when that check alone is broken. Shapes that are merely "obviously wrong" are rejected by
/// whichever check runs first and pin nothing.

/// @dev Returns success and no data. A Safe with no fallback handler and an EIP-1167 clone over a
/// codeless implementation both answer this way, which is what makes this the realistic shape.
contract EmptyReturn {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @dev 32 bytes holding the value 32: a plausible offset word with nothing behind it. Pins the
/// minimum-size check - without it, `ret.length - 64` underflows and panics.
contract ShortWord {
    fallback() external {
        assembly {
            mstore(0, 32)
            return(0, 32)
        }
    }
}

/// @dev 96 bytes whose offset word is enormous while the length word is 0. The length check passes,
/// so only the canonical-offset check can reject this one.
contract WildOffset {
    fallback() external {
        assembly {
            mstore(0, not(0))
            mstore(32, 0)
            mstore(64, 0)
            return(0, 96)
        }
    }
}

/// @dev A canonical offset and a length one word past the body: 64 bytes returned, 32 claimed. Sits
/// just outside the bound, so only an exact bounds check rejects it - a length of, say, 1000 would be
/// caught by a broken check too and would prove nothing.
contract LengthOverrunsBody {
    fallback() external {
        assembly {
            mstore(0, 32)
            mstore(32, 32)
            return(0, 64)
        }
    }
}

/// @dev REVERTS carrying a payload that is itself a valid ABI string - no `Error(string)` selector in
/// front of it. Only the `success` check can reject this: the bytes decode perfectly.
contract BareStringRevert {
    fallback() external {
        assembly {
            mstore(0, 32)
            mstore(32, 23)
            mstore(64, "BurnMintTokenPool 1.5.1")
            revert(0, 96)
        }
    }
}

/// @dev The control: answers a real `typeAndVersion()`, so a hardened reader is not mistaken for a
/// broken one.
contract RealTypeAndVersion {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.5.1";
    }
}

/// @dev 128 bytes: an offset, a length of 3, and room for only 2 entries. Sized so the element size is
/// what decides - 3 is within the 64 remaining BYTES, but 3 addresses need 96. A check that forgot to
/// multiply by the element size accepts this and the decode reverts.
contract ArrayLengthOverrunsBody {
    fallback() external {
        assembly {
            mstore(0, 32)
            mstore(32, 3)
            mstore(64, 0)
            mstore(96, 0)
            return(0, 128)
        }
    }
}

/// @dev A length of 2^255. Multiplying it by a 32-byte element size overflows a uint256, which in
/// Solidity 0.8 PANICS - in the caller's frame, past any catch, the same class as the decode itself.
/// Only the overflow guard rejects this; the bounds check never gets to run.
contract ArrayLengthOverflowsWordSize {
    fallback() external {
        assembly {
            mstore(0, 32)
            mstore(32, shl(255, 1))
            mstore(64, 0)
            return(0, 96)
        }
    }
}
