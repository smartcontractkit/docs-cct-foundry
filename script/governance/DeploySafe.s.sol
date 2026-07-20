// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ISafe, ISafeProxyFactory, SafeCanonical} from "../../src/base/ISafe.sol";

/// @notice Deploys a Safe from the canonical Safe v1.4.1 stack:
///         `SafeProxyFactory.createProxyWithNonce(SafeL2, setup(...), saltNonce)`.
///
/// Because the factory, singleton, and fallback handler live at the SAME address on every supported
/// chain and `createProxyWithNonce` is CREATE2, the same owners + threshold + saltNonce yield the
/// SAME Safe address on every chain - which is what a mirrored multi-chain fleet needs. The script
/// predicts the CREATE2 address first, asserts the deployment lands on it, and is idempotent: if the
/// predicted address already has code (the Safe was already deployed, here or on a mirrored chain
/// setup rerun), it logs and returns instead of reverting.
///
/// Environment Variables:
///   SAFE_OWNERS      (required) comma-separated owner addresses, e.g. "0xabc...,0xdef...,0x123..."
///   SAFE_THRESHOLD   (required) number of owner signatures required (1..len(SAFE_OWNERS))
///   SAFE_SALT_NONCE  (optional) CREATE2 salt nonce, default 0 - reuse the SAME value on every chain
///                    to mirror the address
contract DeploySafe is Script {
    function run() external returns (address safe) {
        address[] memory owners = vm.envAddress("SAFE_OWNERS", ",");
        uint256 threshold = vm.envUint("SAFE_THRESHOLD");
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));

        require(owners.length > 0, "SAFE_OWNERS must list at least one owner");
        require(threshold >= 1 && threshold <= owners.length, "SAFE_THRESHOLD must be in [1, len(SAFE_OWNERS)]");
        require(
            SafeCanonical.PROXY_FACTORY.code.length > 0 && SafeCanonical.SAFE_L2_SINGLETON.code.length > 0,
            "Canonical Safe v1.4.1 stack not deployed on this chain (factory/singleton have no code)"
        );

        bytes memory initializer = abi.encodeCall(
            ISafe.setup,
            (
                owners,
                threshold,
                address(0), // no setup delegatecall
                "",
                SafeCanonical.COMPATIBILITY_FALLBACK_HANDLER,
                address(0), // no payment token
                0, // no payment
                payable(address(0))
            )
        );
        address predicted = predictSafeAddress(initializer, saltNonce);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔐 Deploy Safe (canonical v1.4.1, CREATE2)");
        console.log("========================================");
        console.log(string.concat("Owners:            ", vm.toString(owners.length)));
        for (uint256 i = 0; i < owners.length; i++) {
            console.log(string.concat("  [", vm.toString(i), "] ", vm.toString(owners[i])));
        }
        console.log(string.concat("Threshold:         ", vm.toString(threshold)));
        console.log(string.concat("Salt nonce:        ", vm.toString(saltNonce)));
        console.log(string.concat("Predicted address: ", vm.toString(predicted)));

        if (predicted.code.length > 0) {
            console.log(unicode"✅ Safe already deployed at the predicted address; nothing to do.");
            console.log("========================================");
            return predicted;
        }

        vm.startBroadcast();
        safe = ISafeProxyFactory(SafeCanonical.PROXY_FACTORY)
            .createProxyWithNonce(SafeCanonical.SAFE_L2_SINGLETON, initializer, saltNonce);
        vm.stopBroadcast();

        require(safe == predicted, "Deployed Safe address != CREATE2 prediction");
        console.log(unicode"✅ Safe deployed.");
        console.log(string.concat("Safe address:      ", vm.toString(safe)));
        console.log("Same owners + threshold + salt nonce reproduce this address on every chain");
        console.log("with the canonical v1.4.1 stack (CREATE2 same-address property).");
        console.log("========================================");
        console.log("");
    }

    /// @notice Predicts the CREATE2 address `createProxyWithNonce` will deploy to:
    ///         salt = keccak256(keccak256(initializer) || saltNonce), init code = proxyCreationCode ++
    ///         abi.encode(singleton).
    function predictSafeAddress(bytes memory initializer, uint256 saltNonce) public pure returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes memory deploymentData = abi.encodePacked(
            ISafeProxyFactory(SafeCanonical.PROXY_FACTORY).proxyCreationCode(),
            uint256(uint160(SafeCanonical.SAFE_L2_SINGLETON))
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), SafeCanonical.PROXY_FACTORY, salt, keccak256(deploymentData))
                    )
                )
            )
        );
    }
}
