// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

/// @title HelperConfigGoldenDataTest
/// @notice Golden-data parity for the `config/chains` JSON: the addresses, selectors, and the genuinely
/// hand-authored key (`chainNameIdentifier`) below are pinned as LITERALS captured
/// from HelperConfig — they must NOT change.
/// @dev The API-served identity/metadata fields (`chainName`/`displayName`, `chainFamily`, `explorerUrl`,
/// `nativeCurrencySymbol`) are SOURCED from the CCIP REST API by the config sync and pinned to the API
/// truth (captured live 2026-07-09): 0g `chainName` "0g Galileo 1" / `explorerUrl` ".../0g.ai" /
/// `nativeCurrencySymbol` "0G", Ink `nativeCurrencySymbol` "ETH" (Ink settles in ETH), Mantle
/// `explorerUrl` "explorer.sepolia.mantle.xyz", and Solana `explorerUrl` the devnet explorer. The API is
/// the source of truth for these fields.
/// No fork needed: `HelperConfig` reads local JSON only.
contract HelperConfigGoldenDataTest is Test {
    HelperConfig internal helperConfig;

    function setUp() public {
        helperConfig = new HelperConfig();
    }

    function _assertConfig(
        HelperConfig.NetworkConfig memory c,
        uint64 chainSelector,
        address router,
        address rmnProxy,
        address tokenAdminRegistry,
        address registryModuleOwnerCustom,
        address link,
        string memory chainName,
        string memory chainNameIdentifier,
        string memory explorerUrl,
        string memory nativeCurrencySymbol,
        string memory chainFamily
    ) internal pure {
        assertEq(c.chainSelector, chainSelector, "chainSelector");
        assertEq(c.router, router, "router");
        assertEq(c.rmnProxy, rmnProxy, "rmnProxy");
        assertEq(c.tokenAdminRegistry, tokenAdminRegistry, "tokenAdminRegistry");
        assertEq(c.registryModuleOwnerCustom, registryModuleOwnerCustom, "registryModuleOwnerCustom");
        assertEq(c.link, link, "link");
        assertEq(c.chainName, chainName, "chainName");
        assertEq(c.chainNameIdentifier, chainNameIdentifier, "chainNameIdentifier");
        assertEq(c.explorerUrl, explorerUrl, "explorerUrl");
        assertEq(c.nativeCurrencySymbol, nativeCurrencySymbol, "nativeCurrencySymbol");
        assertEq(c.chainFamily, chainFamily, "chainFamily");
    }

    function test_EthereumSepolia_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getNetworkConfig(11155111),
            16015286601757825753,
            0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
            0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
            0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
            0xa3c796d480638d7476792230da1E2ADa86e031b0,
            0x779877A7B0D9E8603169DdbD7836e478b4624789,
            "Ethereum Sepolia",
            "ETHEREUM_SEPOLIA",
            "https://sepolia.etherscan.io",
            "ETH",
            "evm"
        );
    }

    function test_ZeroGTestnet_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getNetworkConfig(16602),
            6892437333620424805,
            0xD610B8f58689de7755947C05342A2DFaC30ebD57,
            0x995ab3eC29E1660A93cFddAA19C710A1b5afCCc9,
            0x23a5084Fa78104F3DF11C63Ae59fcac4f6AD9DeE,
            0x0820f975ce90EE5c508657F0C58b71D1fcc85cE0,
            0xe5e3a4fF1773d043a387b16Ceb3c91cC49bAFD54,
            "0g Galileo 1",
            "0G_GALILEO_TESTNET",
            "https://chainscan-galileo.0g.ai",
            "0G",
            "evm"
        );
    }

    function test_PlumeTestnet_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getNetworkConfig(98867),
            13874588925447303949,
            0x5e5Fd4720E1CE826138D043aF578D69f48af502F,
            0xAa3ae5481EE445711252131f1516922D0962916A,
            0x855cF0d18A0BeBEDA7c1CD2F943686120cCCC6bd,
            0x693926456C8b210f56E29Bc5b4514B32A5224c88,
            0xB97e3665AEAF96BDD6b300B2e0C93C662104A068,
            "Plume Testnet",
            "PLUME_TESTNET",
            "https://testnet-explorer.plume.org",
            "PLUME",
            "evm"
        );
    }

    function test_InkSepolia_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getNetworkConfig(763373),
            9763904284804119144,
            0x17fCda531D8E43B4e2a2A2492FBcd4507a1685A1,
            0x84017cfddD12D319E5bBf090e0de6d55B78160Cb,
            0x3A849a05a590FeaEf26c2d425241A2BF29307161,
            0xaB018890bBdDf9B80E21d1c335c5f6acdbE0f5D6,
            0x3423C922911956b1Ccbc2b5d4f38216a6f4299b4,
            "Ink Sepolia",
            "INK_SEPOLIA",
            "https://explorer-sepolia.inkonchain.com",
            "ETH",
            "evm"
        );
    }

    function test_MantleSepolia_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getNetworkConfig(5003),
            8236463271206331221,
            0xFd33fd627017fEf041445FC19a2B6521C9778f86,
            0xcCB84Ec3F6AFdD2052134f74aaAc95Ae41A7B333,
            0x0F1eE88A582f31d92510E300fc1330AA5a525D51,
            0xf76cE612250eeEb8889F49FBCB11f1c2705305F6,
            0x22bdEdEa0beBdD7CfFC95bA53826E55afFE9DE04,
            "Mantle Sepolia",
            "MANTLE_SEPOLIA",
            "https://explorer.sepolia.mantle.xyz",
            "MNT",
            "evm"
        );
    }

    function test_SolanaDevnet_MatchesPreMigrationValues() public view {
        _assertConfig(
            helperConfig.getSolanaDevnetConfig(),
            16423721717087811551,
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            "Solana Devnet",
            "SOLANA_DEVNET",
            "https://explorer.solana.com?cluster=devnet",
            "SOL",
            "svm"
        );
    }

    /// @dev The lookup helpers must keep resolving exactly as before the migration.
    function test_LookupHelpers_MatchPreMigrationBehavior() public {
        // parseChainName: identifier -> chain ID (EVM only)
        assertEq(helperConfig.parseChainName("ETHEREUM_SEPOLIA"), 11155111);
        assertEq(helperConfig.parseChainName("0G_GALILEO_TESTNET"), 16602);
        assertEq(helperConfig.parseChainName("PLUME_TESTNET"), 98867);
        assertEq(helperConfig.parseChainName("INK_SEPOLIA"), 763373);
        assertEq(helperConfig.parseChainName("MANTLE_SEPOLIA"), 5003);

        // getChainNameBySelector: selector -> display name (incl. non-EVM + unknown)
        assertEq(helperConfig.getChainNameBySelector(16015286601757825753), "Ethereum Sepolia");
        assertEq(helperConfig.getChainNameBySelector(16423721717087811551), "Solana Devnet");
        assertEq(helperConfig.getChainNameBySelector(1), "Unknown");

        // getDestChainConfig: dest-name dispatch incl. the zero config for unknown names
        assertEq(helperConfig.getDestChainConfig("SOLANA_DEVNET").chainSelector, 16423721717087811551);
        assertEq(helperConfig.getDestChainConfig("ZERO_G_TESTNET").chainSelector, 6892437333620424805);
        assertEq(helperConfig.getDestChainConfig("AVALANCHE_FUJI").chainSelector, 0);
        assertEq(helperConfig.getDestChainConfig("AVALANCHE_FUJI").chainFamily, "");

        // getExplorerUrl composition
        assertEq(
            helperConfig.getExplorerUrl(11155111, "/address/", 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59),
            "https://sepolia.etherscan.io/address/0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59"
        );

        // Unsupported chain IDs must keep reverting with the same reason
        vm.expectRevert(bytes("Unsupported chain ID"));
        helperConfig.getNetworkConfig(43113);
    }
}
