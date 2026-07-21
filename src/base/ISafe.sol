// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interface of a Safe (v1.3.0+) - only the surface the Safe execution mode needs:
///         nonce/owner reads, the on-chain `safeTxHash` computation, and `execTransaction`. Declared
///         locally so the repo does not vendor the full safe-smart-account package for four functions.
/// @dev `operation` is `uint8` here (0 = CALL, 1 = DELEGATECALL); Safe declares it as `Enum.Operation`,
///      which ABI-encodes identically.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function nonce() external view returns (uint256);

    function domainSeparator() external view returns (bytes32);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);

    function isOwner(address owner) external view returns (bool);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

/// @notice Minimal interface of the canonical `SafeProxyFactory` (v1.4.1).
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);

    function proxyCreationCode() external pure returns (bytes memory);
}

/// @notice Minimal interface of the canonical `MultiSendCallOnly` (v1.4.1): batches CALLs only, so a
///         malicious batch entry can never DELEGATECALL out of the Safe's context.
interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}

/// @notice Canonical Safe v1.4.1 deployment addresses. The Safe deployment stack is deployed at the
///         SAME address on every supported chain (deterministic CREATE2 from the canonical deployer),
///         which is what lets `DeploySafe` mirror one Safe address across a fleet of chains.
/// @dev Source: safe-global/safe-deployments v1.4.1 (verified on-chain on Ethereum Sepolia).
library SafeCanonical {
    /// @notice `SafeProxyFactory` v1.4.1.
    address internal constant PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    /// @notice `SafeL2` v1.4.1 singleton (emits the extra L2 events indexers rely on; safe on L1 too).
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    /// @notice `CompatibilityFallbackHandler` v1.4.1 (gives the Safe ERC-165/1271 compatibility).
    address internal constant COMPATIBILITY_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    /// @notice `MultiSendCallOnly` v1.4.1 (the batching target for multi-call Safe transactions).
    address internal constant MULTI_SEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
}
