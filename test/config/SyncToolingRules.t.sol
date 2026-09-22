// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SyncCcipConfig} from "../../script/config/SyncCcipConfig.s.sol";

/// @notice Pins the pure rules of the chain-config tooling (`script/config/SyncCcipConfig.s.sol`):
/// chain-name validation (names become file paths and shell arguments - path traversal and shell
/// metacharacters must be refused up front) and the derived-default conventions used by add-chain.
contract SyncToolingRulesTest is Test {
    SyncCcipConfig internal sync;

    function setUp() public {
        sync = new SyncCcipConfig();
    }

    function test_ValidChainNamesAccepted() public view {
        assertTrue(sync.isValidChainName("ethereum-testnet-sepolia-mantle-1"));
        assertTrue(sync.isValidChainName("0g-testnet-galileo-1"));
        assertTrue(sync.isValidChainName("sepolia"));
        assertTrue(sync.isValidChainName("chain2"));
    }

    /// @dev Underscore is part of canonical CCIP selectorNames (BNB, opBNB, Gnosis). `make discover`
    /// prints these verbatim and instructs the operator to pass them to add-chain, and the config
    /// `name` must stay byte-identical to the selectorName (the sync join key), so they MUST validate.
    function test_UnderscoreSelectorNamesAccepted() public view {
        assertTrue(sync.isValidChainName("binance_smart_chain-mainnet"));
        assertTrue(sync.isValidChainName("binance_smart_chain-testnet-opbnb-1"));
        assertTrue(sync.isValidChainName("gnosis_chain-testnet-chiado"));
    }

    function test_PathTraversalAndSeparatorNamesRejected() public view {
        assertFalse(sync.isValidChainName("../evil"), "path traversal");
        assertFalse(sync.isValidChainName("evil/sub"), "path separator");
        assertFalse(sync.isValidChainName("..."), "dots");
        assertFalse(sync.isValidChainName(""), "empty");
        assertFalse(sync.isValidChainName("_evil"), "leading underscore");
    }

    function test_ShellUnsafeNamesRejected() public view {
        assertFalse(sync.isValidChainName("evil name"), "space");
        assertFalse(sync.isValidChainName("Evil"), "uppercase");
        assertFalse(sync.isValidChainName("-evil"), "leading dash");
        assertFalse(sync.isValidChainName("evil;rm"), "shell metacharacter");
    }

    function test_ChainNameIdentifierDerivation() public view {
        assertEq(sync.chainNameIdentifierFor("ethereum-testnet-sepolia-mantle-1"), "ETHEREUM_TESTNET_SEPOLIA_MANTLE_1");
        assertEq(sync.chainNameIdentifierFor("ethereum-testnet-sepolia"), "ETHEREUM_TESTNET_SEPOLIA");
        // A selectorName with underscores keeps them (already valid shell identifier characters).
        assertEq(sync.chainNameIdentifierFor("binance_smart_chain-testnet"), "BINANCE_SMART_CHAIN_TESTNET");
    }

    /// @dev A leading digit cannot start a POSIX shell env-var name, so the derivation prefixes `_`;
    /// otherwise the derived rpcEnv (`0G_..._RPC_URL`) is unsettable and the doctor's RPC rung goes
    /// blind. See VerifyChain._checkRpc / _isValidEnvName.
    function test_ChainNameIdentifierLeadingDigitPrefixed() public view {
        assertEq(sync.chainNameIdentifierFor("0g-testnet-galileo-1"), "_0G_TESTNET_GALILEO_1");
    }

    /// @dev Pins THE single list of API-synced ccip{} address fields (shared by the sync write and
    /// the drift check) to the committed `config/chains/<name>.json` schema.
    function test_CcipAddressKeysMatchSchema() public view {
        string[7] memory keys = sync.ccipAddressKeys();
        string[7] memory expected = [
            "router",
            "rmnProxy",
            "tokenAdminRegistry",
            "registryModuleOwnerCustom",
            "link",
            "feeQuoter",
            "tokenPoolFactory"
        ];
        string memory configJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
        for (uint256 i = 0; i < keys.length; i++) {
            assertEq(keys[i], expected[i], "key order changed");
            assertTrue(
                vm.keyExistsJson(configJson, string.concat(".ccip.", keys[i])),
                string.concat("committed schema lacks .ccip.", keys[i])
            );
        }
    }

    /// @dev Pins the committed EVM and non-EVM fixtures to EXACTLY `ccipAddressKeys()` + `feeTokens`
    /// (eight keys, no more and no less). Three lists must agree but have no compile-time tie: the sync
    /// generators (`_buildCcipJson` / `_zeroedCcipJson`, which loop `ccipAddressKeys()`), the doctor's
    /// hardcoded `.ccip.*` schema requirement, and these fixtures. Adding a ccip contract to
    /// `ccipAddressKeys()` without also updating both fixtures (and the doctor's schema list) turns this
    /// red instead of silently shipping a non-EVM config that passes schema while missing the new key.
    function test_CcipBlockShapeIsExactlyTheKeyList() public view {
        _assertCcipBlockExact("config/chains/ethereum-testnet-sepolia.json");
        _assertCcipBlockExact("config/chains/solana-devnet.json");
    }

    /// @dev The native plane is NON-EVM ONLY and additive: the EVM configs must not grow it (their
    /// addresses are EVM-typed in `ccip{}`), and the non-EVM ones must carry a real value for every
    /// key the API serves for that family - the committed zeros in `ccip{}` are the EVM-typed
    /// skeleton three `.ccip.*` readers require, not chain facts.
    function test_CcipNativeIsNonEvmOnly() public view {
        string memory evm = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
        assertFalse(vm.keyExistsJson(evm, ".ccipNative"), "EVM config grew a ccipNative block");
        assertFalse(vm.keyExistsJson(evm, ".nativeChainId"), "EVM config grew a nativeChainId");

        string memory svm = vm.readFile("config/chains/solana-devnet.json");
        assertEq(vm.parseJsonString(svm, ".chainId"), "0", "the chainId sentinel must stay 0");
        assertTrue(bytes(vm.parseJsonString(svm, ".nativeChainId")).length > 0, "solana nativeChainId empty");
        string[3] memory svmKeys = ["router", "rmnProxy", "feeQuoter"];
        for (uint256 i = 0; i < svmKeys.length; i++) {
            assertTrue(
                bytes(vm.parseJsonString(svm, string.concat(".ccipNative.", svmKeys[i]))).length > 0,
                string.concat("solana ccipNative.", svmKeys[i], " empty")
            );
        }
        // Both pool-program variants, and distinct: one program id copied into both keys is the
        // mutation a bare non-empty check misses, and lock-release is a first-class Solana use case.
        string[2] memory programs = sync.tokenPoolProgramKeys();
        string memory burnMint = vm.parseJsonString(svm, ".ccipNative.tokenPoolPrograms.burnMint");
        string memory lockRelease = vm.parseJsonString(svm, ".ccipNative.tokenPoolPrograms.lockRelease");
        assertEq(programs[0], "burnMint", "program key order changed");
        assertEq(programs[1], "lockRelease", "program key order changed");
        assertTrue(bytes(burnMint).length > 0 && bytes(lockRelease).length > 0, "a pool program is empty");
        assertTrue(keccak256(bytes(burnMint)) != keccak256(bytes(lockRelease)), "one program id in both keys");
    }

    /// @dev Aptos is the THIRD shape and is out of scope for writes, but the schema is family-generic:
    /// a key the API does not serve for a family must be ABSENT, never a zero or an empty string.
    function test_CcipNativeOmitsUnservedKeys() public view {
        string memory aptos = vm.readFile("config/chains/aptos-testnet.json");
        assertEq(vm.parseJsonString(aptos, ".chainId"), "0", "the chainId sentinel must stay 0");
        assertTrue(bytes(vm.parseJsonString(aptos, ".ccipNative.tokenAdminRegistry")).length > 0, "aptos TAR missing");
        assertFalse(vm.keyExistsJson(aptos, ".ccipNative.tokenPoolPrograms"), "aptos has no pool programs");
        assertFalse(vm.keyExistsJson(aptos, ".ccipNative.registryModuleOwnerCustom"), "aptos has no registryModule");

        string memory svm = vm.readFile("config/chains/solana-devnet.json");
        assertFalse(vm.keyExistsJson(svm, ".ccipNative.tokenAdminRegistry"), "solana has no tokenAdminRegistry");
    }

    /// @dev Every `ccipNative{}` key present in a committed config must come from the shared key list
    /// (plus `tokenPoolPrograms`), so the writer, the drift-check and the files cannot diverge.
    function test_CcipNativeKeysAreFromTheKeyList() public view {
        _assertNativeKeysKnown("config/chains/solana-devnet.json");
        _assertNativeKeysKnown("config/chains/aptos-testnet.json");
    }

    function _assertNativeKeysKnown(string memory path) internal view {
        string memory json = vm.readFile(path);
        string[6] memory known = sync.ccipNativeKeys();
        string[] memory actual = vm.parseJsonKeys(json, ".ccipNative");
        for (uint256 i = 0; i < actual.length; i++) {
            bool found = keccak256(bytes(actual[i])) == keccak256(bytes("tokenPoolPrograms"));
            for (uint256 k = 0; k < known.length && !found; k++) {
                found = keccak256(bytes(actual[i])) == keccak256(bytes(known[k]));
            }
            assertTrue(found, string.concat(path, ": unknown ccipNative key ", actual[i]));
        }
    }

    function _assertCcipBlockExact(string memory path) internal view {
        string memory json = vm.readFile(path);
        string[7] memory keys = sync.ccipAddressKeys();
        string[] memory actual = vm.parseJsonKeys(json, ".ccip");
        assertEq(actual.length, keys.length + 1, string.concat(path, ": .ccip must have exactly 8 keys"));
        for (uint256 i = 0; i < keys.length; i++) {
            assertTrue(
                vm.keyExistsJson(json, string.concat(".ccip.", keys[i])), string.concat(path, " lacks .ccip.", keys[i])
            );
        }
        assertTrue(vm.keyExistsJson(json, ".ccip.feeTokens"), string.concat(path, " lacks .ccip.feeTokens"));
    }
}
