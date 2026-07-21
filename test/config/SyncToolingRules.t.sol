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
