// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainHandlers} from "../../script/utils/ChainHandlers.s.sol";

/// @dev External wrapper so vm.expectRevert can observe reverts from the internal
/// library functions (internal calls are inlined into the test otherwise).
contract ChainHandlersHarness {
    function prepareChainAddressData(string calldata addr, ChainHandlers.ChainFamily family)
        external
        pure
        returns (bytes memory)
    {
        return ChainHandlers._prepareChainAddressData(addr, family);
    }

    function validateChainAddress(string calldata addr, ChainHandlers.ChainFamily family) external pure returns (bool) {
        return ChainHandlers._validateChainAddress(addr, family);
    }

    function encodeBase58(bytes calldata data) external pure returns (string memory) {
        return ChainHandlers._encodeBase58(data);
    }
}

/// @notice Unit tests (no fork) for script/utils/ChainHandlers.s.sol: EVM address encoding,
/// SVM base58 decoding against independently derived bytes, and malformed-input reverts.
contract ChainHandlersTest is Test {
    // Known Solana devnet/mainnet public keys with their raw 32-byte values derived from an
    // INDEPENDENT base58 decode (Python), not from the code under test.
    string internal constant SVM_KEY = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    bytes internal constant SVM_KEY_BYTES = hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61";
    string internal constant SVM_KEY_2 = "3emsAVdmGKERbHjmGfQ6oZ1e35dkf5iYcS6U4CPKFVaa";
    bytes internal constant SVM_KEY_2_BYTES = hex"276497ba0bb8659172b72edd8c66e18f561764d9c86a610a3a7e0f79c0baf9db";

    ChainHandlersHarness internal harness;

    function setUp() public {
        harness = new ChainHandlersHarness();
    }

    // ─── EVM ─────────────────────────────────────────────────────────────────

    function test_Evm_EncodesToAbiEncodedAddress() public view {
        address addr = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
        bytes memory encoded = harness.prepareChainAddressData(vm.toString(addr), ChainHandlers.ChainFamily.EVM);
        assertEq(encoded, abi.encode(addr), "EVM encoding must equal abi.encode(address)");
        assertEq(encoded.length, 32, "EVM encoding must be one ABI word");
    }

    function test_Evm_ValidateRejectsMalformedAddresses() public view {
        assertFalse(harness.validateChainAddress("0x1234", ChainHandlers.ChainFamily.EVM), "too short");
        assertFalse(
            harness.validateChainAddress("0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A590x", ChainHandlers.ChainFamily.EVM),
            "missing 0x prefix"
        );
        assertFalse(
            harness.validateChainAddress("0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363AZZ", ChainHandlers.ChainFamily.EVM),
            "non-hex characters"
        );
    }

    function test_Evm_MalformedAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainHandlers.InvalidChainAddress.selector, "0x1234", "evm"));
        harness.prepareChainAddressData("0x1234", ChainHandlers.ChainFamily.EVM);
    }

    // ─── SVM (Solana) ────────────────────────────────────────────────────────

    function test_Svm_KnownPubkeysDecodeToKnownBytes() public view {
        assertEq(
            harness.prepareChainAddressData(SVM_KEY, ChainHandlers.ChainFamily.SVM),
            SVM_KEY_BYTES,
            "base58 decode mismatch vs independent decode (key 1)"
        );
        assertEq(
            harness.prepareChainAddressData(SVM_KEY_2, ChainHandlers.ChainFamily.SVM),
            SVM_KEY_2_BYTES,
            "base58 decode mismatch vs independent decode (key 2)"
        );
    }

    function test_Svm_EncodeBase58RoundTrip() public view {
        assertEq(harness.encodeBase58(SVM_KEY_BYTES), SVM_KEY, "encodeBase58 round trip mismatch");
        assertEq(harness.encodeBase58(SVM_KEY_2_BYTES), SVM_KEY_2, "encodeBase58 round trip mismatch");
    }

    function test_Svm_ValidateRejectsMalformedAddresses() public view {
        // Too short to be a 32-byte key.
        assertFalse(harness.validateChainAddress("abc", ChainHandlers.ChainFamily.SVM), "too short");
        // Right length but contains characters outside the base58 alphabet ('O' and 'l').
        assertFalse(
            harness.validateChainAddress("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDtOl", ChainHandlers.ChainFamily.SVM),
            "invalid base58 characters"
        );
    }

    function test_Svm_TooShortAddressRevertsInvalidChainAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ChainHandlers.InvalidChainAddress.selector, "abc", "svm"));
        harness.prepareChainAddressData("abc", ChainHandlers.ChainFamily.SVM);
    }

    function test_Svm_InvalidBase58CharacterReverts() public {
        // Length passes the 32-44 char check, so the failure surfaces from the base58
        // decoder itself as a string revert (not the InvalidChainAddress custom error).
        vm.expectRevert(bytes("ChainHandlers: invalid base58 character"));
        harness.prepareChainAddressData("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDtOl", ChainHandlers.ChainFamily.SVM);
    }
}
