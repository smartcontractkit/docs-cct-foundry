// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title SafeTxHash
/// @notice Independent EIP-712 recompute of a Safe transaction hash (`safeTxHash`), matching Safe
///         v1.3.0+ (`domainSeparator()` is chainId-based). The Safe execution mode cross-checks this
///         local recompute against the Safe's own `getTransactionHash` before any signature is
///         produced - two independent derivations must agree, the same control a production signer
///         applies with the `safe-hash` tool.
library SafeTxHash {
    /// @notice `keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")` - the Safe >= 1.3.0
    ///         domain, which binds signatures to one chain and one Safe.
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    /// @notice The SafeTx EIP-712 typehash.
    /// @dev GOTCHA: the type string must end in `uint256 nonce` - the EIP-712 STRUCT FIELD name - not
    ///      `_nonce`, the Solidity PARAMETER name Safe's `getTransactionHash` happens to use. Encoding
    ///      `_nonce` yields a wrong typehash and a hash that never matches signer devices.
    ///      `test/governance/SafeTxHash.t.sol` pins this as a regression test.
    bytes32 internal constant SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );

    /// @notice One Safe transaction, as the EIP-712 SafeTx struct orders its fields.
    struct SafeTx {
        address to;
        uint256 value;
        bytes data;
        uint8 operation; // 0 = CALL, 1 = DELEGATECALL
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
    }

    /// @notice The Safe's EIP-712 domain separator, recomputed locally.
    function _domainSeparator(uint256 chainId, address safe) internal pure returns (bytes32 result) {
        bytes memory encoded = abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, safe);
        assembly {
            result := keccak256(add(encoded, 0x20), mload(encoded))
        }
    }

    /// @notice The EIP-712 struct hash of one SafeTx (dynamic `data` hashed per EIP-712).
    function _structHash(SafeTx memory t) internal pure returns (bytes32 result) {
        bytes memory encoded = abi.encode(
            SAFE_TX_TYPEHASH,
            t.to,
            t.value,
            keccak256(t.data),
            t.operation,
            t.safeTxGas,
            t.baseGas,
            t.gasPrice,
            t.gasToken,
            t.refundReceiver,
            t.nonce
        );
        assembly {
            result := keccak256(add(encoded, 0x20), mload(encoded))
        }
    }

    /// @notice The full `safeTxHash`: `keccak256(0x1901 || domainSeparator || structHash)`. Must equal
    ///         the Safe's on-chain `getTransactionHash` for the same inputs.
    function _compute(uint256 chainId, address safe, SafeTx memory t) internal pure returns (bytes32 result) {
        bytes memory encoded =
            abi.encodePacked(bytes1(0x19), bytes1(0x01), _domainSeparator(chainId, safe), _structHash(t));
        assembly {
            result := keccak256(add(encoded, 0x20), mload(encoded))
        }
    }
}
