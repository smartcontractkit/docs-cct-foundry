// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SyncCcipConfig} from "../../script/config/SyncCcipConfig.s.sol";

/// @notice Pins the pure rules of the chain-config tooling (`script/config/SyncCcipConfig.s.sol`):
/// chain-name validation (names become file paths and shell arguments — path traversal and shell
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

    function test_PathTraversalAndSeparatorNamesRejected() public view {
        assertFalse(sync.isValidChainName("../evil"), "path traversal");
        assertFalse(sync.isValidChainName("evil/sub"), "path separator");
        assertFalse(sync.isValidChainName("..."), "dots");
        assertFalse(sync.isValidChainName(""), "empty");
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
        assertEq(sync.chainNameIdentifierFor("0g-testnet-galileo-1"), "0G_TESTNET_GALILEO_1");
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
}
