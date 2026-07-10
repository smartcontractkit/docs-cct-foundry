// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice Pins the config-sync transform against a REAL, committed CCIP REST API v2 response
/// (`test/fixtures/ccip-api/chain-16015286601757825753.json`, `GET /chains/{selector}` for
/// Ethereum Sepolia). Offline (no ffi, no network): asserts that selecting the `isActive: true`
/// entry per contract type — exactly what `script/config/ccip-config-source.sh` does with jq —
/// reproduces the committed `config/chains/ethereum-testnet-sepolia.json` `ccip{}` block, including the
/// API->repo key mapping (`rmn` -> `rmnProxy`, `registryModule` -> `registryModuleOwnerCustom`,
/// LINK fee token -> `link`). The end-to-end write path (jq + `vm.writeJson`, idempotency, extras
/// preservation) is exercised by `script/config/test-tooling.sh` against a local fixture server.
contract SyncFixtureTransformTest is Test {
    string internal fixtureJson;
    string internal configJson;

    function setUp() public {
        fixtureJson = vm.readFile("test/fixtures/ccip-api/chain-16015286601757825753.json");
        configJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
    }

    /// @dev Selects the `isActive: true` entry for a chainConfig contract type (the jq `act()` rule).
    function _activeAddress(string memory apiKey) internal view returns (address) {
        string memory base = string.concat(".chainConfig.", apiKey);
        for (uint256 i = 0; i < 16; i++) {
            string memory entry = string.concat(base, "[", vm.toString(i), "]");
            if (!vm.keyExistsJson(fixtureJson, entry)) break;
            if (vm.parseJsonBool(fixtureJson, string.concat(entry, ".isActive"))) {
                return vm.parseJsonAddress(fixtureJson, string.concat(entry, ".address"));
            }
        }
        revert(string.concat("no active ", apiKey, " entry in fixture"));
    }

    function test_FixtureIdentityMatchesCommittedConfig() public view {
        assertEq(
            vm.parseJsonUint(fixtureJson, ".chain.chainId"),
            vm.parseJsonUint(configJson, ".chainId"),
            "fixture chainId != config chainId"
        );
        assertEq(
            vm.parseJsonUint(fixtureJson, ".chain.chainSelector"),
            vm.parseJsonUint(configJson, ".chainSelector"),
            "fixture selector != config selector"
        );
        assertEq(vm.parseJsonString(fixtureJson, ".chain.chainFamily"), "EVM", "fixture chainFamily");
    }

    function test_ActiveSelectionMatchesCommittedCcipBlock() public view {
        // API key -> repo ccip{} key mapping, exactly as the fetch script emits it.
        assertEq(_activeAddress("router"), vm.parseJsonAddress(configJson, ".ccip.router"), "router");
        assertEq(_activeAddress("rmn"), vm.parseJsonAddress(configJson, ".ccip.rmnProxy"), "rmn -> rmnProxy");
        assertEq(
            _activeAddress("tokenAdminRegistry"),
            vm.parseJsonAddress(configJson, ".ccip.tokenAdminRegistry"),
            "tokenAdminRegistry"
        );
        assertEq(
            _activeAddress("registryModule"),
            vm.parseJsonAddress(configJson, ".ccip.registryModuleOwnerCustom"),
            "registryModule -> registryModuleOwnerCustom"
        );
        assertEq(_activeAddress("feeQuoter"), vm.parseJsonAddress(configJson, ".ccip.feeQuoter"), "feeQuoter");
        assertEq(
            _activeAddress("tokenPoolFactory"),
            vm.parseJsonAddress(configJson, ".ccip.tokenPoolFactory"),
            "tokenPoolFactory"
        );
    }

    /// @dev The fixture carries `isActive: false` siblings (an old router + FeeQuoter), so blind
    /// first-entry selection would produce a DIFFERENT config — proves the isActive rule matters.
    function test_InactiveSiblingsExistAndDiffer() public view {
        assertFalse(vm.parseJsonBool(fixtureJson, ".chainConfig.router[1].isActive"), "router[1] should be inactive");
        assertTrue(
            vm.parseJsonAddress(fixtureJson, ".chainConfig.router[1].address") != _activeAddress("router"),
            "inactive router should differ from the active one"
        );
        assertFalse(
            vm.parseJsonBool(fixtureJson, ".chainConfig.feeQuoter[1].isActive"), "feeQuoter[1] should be inactive"
        );
        assertTrue(
            vm.parseJsonAddress(fixtureJson, ".chainConfig.feeQuoter[1].address") != _activeAddress("feeQuoter"),
            "inactive feeQuoter should differ from the active one"
        );
    }

    function test_LinkFeeTokenMatchesCommittedLink() public view {
        address link = address(0);
        for (uint256 i = 0; i < 16; i++) {
            string memory entry = string.concat(".chainConfig.feeTokens[", vm.toString(i), "]");
            if (!vm.keyExistsJson(fixtureJson, entry)) break;
            if (
                keccak256(bytes(vm.parseJsonString(fixtureJson, string.concat(entry, ".tokenSymbol"))))
                    == keccak256(bytes("LINK"))
            ) {
                link = vm.parseJsonAddress(fixtureJson, string.concat(entry, ".tokenAddress"));
                break;
            }
        }
        assertEq(link, vm.parseJsonAddress(configJson, ".ccip.link"), "LINK fee token -> ccip.link");
    }

    function test_FeeTokensMatchCommittedArray() public view {
        address[] memory committed = vm.parseJsonAddressArray(configJson, ".ccip.feeTokens");
        for (uint256 i = 0; i < committed.length; i++) {
            string memory entry = string.concat(".chainConfig.feeTokens[", vm.toString(i), "]");
            assertTrue(vm.keyExistsJson(fixtureJson, entry), "fixture has fewer feeTokens than config");
            assertEq(
                vm.parseJsonAddress(fixtureJson, string.concat(entry, ".tokenAddress")),
                committed[i],
                string.concat("feeTokens[", vm.toString(i), "]")
            );
        }
        // and no extra entries beyond the committed list
        assertFalse(
            vm.keyExistsJson(fixtureJson, string.concat(".chainConfig.feeTokens[", vm.toString(committed.length), "]")),
            "fixture has more feeTokens than config"
        );
    }
}
