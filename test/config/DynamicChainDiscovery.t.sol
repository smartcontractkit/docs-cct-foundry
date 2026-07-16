// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

/// @title DynamicChainDiscoveryTest
/// @notice The end-to-end "zero Solidity changes" proof: dropping a NEW `config/chains/<name>.json`
/// file in (exactly what `make add-chain` produces) makes the chain resolvable through every
/// HelperConfig lookup — by chain ID, by chain name identifier, by selector, as a destination
/// chain, and in the configured-chain enumeration — WITHOUT touching any Solidity dispatch.
/// The scratch config uses a fake-but-valid chain ID / selector / identifier that no hardcoded
/// fast path knows, so it can only resolve via the directory scan. All scratch assertions live in
/// ONE test so the shared `config/chains/` directory sees exactly one write + one delete per run
/// (tests run in parallel; every HelperConfig constructor scans this directory ONCE into a storage
/// cache via `ChainConfig.tryLoad`, which tolerates a concurrently-deleted entry).
contract DynamicChainDiscoveryTest is Test {
    uint256 internal constant SCRATCH_CHAIN_ID = 777000777;
    uint64 internal constant SCRATCH_SELECTOR = 7770007770007770077;
    string internal constant SCRATCH_NAME = "zz-scratch-dynamic";
    string internal constant SCRATCH_IDENTIFIER = "ZZ_SCRATCH_DYNAMIC";

    function setUp() public {
        _clean();
    }

    /// @dev Removes the scratch chain config. The setUp() call is the revert-safe guarantee (a failed
    /// test leaves the file for inspection until the next run); the end-of-test call keeps a green
    /// run residue-free.
    function _clean() private {
        string memory path = string.concat(vm.projectRoot(), "/config/chains/", SCRATCH_NAME, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    /// @dev Writes the scratch `config/chains/<SCRATCH_NAME>.json` in the exact shape
    /// `make add-chain` generates, returning its absolute path so the test can remove it.
    function _writeScratchChain() internal returns (string memory path) {
        path = string.concat(vm.projectRoot(), "/config/chains/", SCRATCH_NAME, ".json");
        vm.writeFile(
            path,
            string.concat(
                "{\n",
                '  "ccip": {\n',
                '    "feeQuoter": "0x0000000000000000000000000000000000000000",\n',
                '    "feeTokens": [],\n',
                '    "link": "0x0000000000000000000000000000000000000001",\n',
                '    "registryModuleOwnerCustom": "0x0000000000000000000000000000000000000004",\n',
                '    "rmnProxy": "0x0000000000000000000000000000000000000003",\n',
                '    "router": "0x0000000000000000000000000000000000000002",\n',
                '    "tokenAdminRegistry": "0x0000000000000000000000000000000000000005",\n',
                '    "tokenPoolFactory": "0x0000000000000000000000000000000000000000"\n',
                "  },\n",
                '  "chainFamily": "evm",\n',
                '  "chainId": "',
                vm.toString(SCRATCH_CHAIN_ID),
                '",\n',
                '  "chainNameIdentifier": "',
                SCRATCH_IDENTIFIER,
                '",\n',
                '  "chainSelector": "',
                vm.toString(SCRATCH_SELECTOR),
                '",\n',
                '  "confirmations": 2,\n',
                '  "displayName": "Zz Scratch Dynamic",\n',
                '  "environment": "testnet",\n',
                '  "explorerUrl": "https://example.invalid",\n',
                '  "name": "',
                SCRATCH_NAME,
                '",\n',
                '  "nativeCurrencySymbol": "ZZZ",\n',
                '  "rpcEnv": "ZZ_SCRATCH_DYNAMIC_RPC_URL"\n',
                "}\n"
            )
        );
    }

    function test_NewChainConfigFile_ResolvesEverywhereWithoutSolidityChange() public {
        _writeScratchChain();
        HelperConfig helperConfig = new HelperConfig();

        // getNetworkConfig(chainId) — the directory-scan fallback resolves every field
        HelperConfig.NetworkConfig memory c = helperConfig.getNetworkConfig(SCRATCH_CHAIN_ID);
        assertEq(c.chainSelector, SCRATCH_SELECTOR, "chainSelector");
        assertEq(c.router, address(2), "router");
        assertEq(c.rmnProxy, address(3), "rmnProxy");
        assertEq(c.registryModuleOwnerCustom, address(4), "registryModuleOwnerCustom");
        assertEq(c.tokenAdminRegistry, address(5), "tokenAdminRegistry");
        assertEq(c.link, address(1), "link");
        assertEq(c.confirmations, 2, "confirmations");
        assertEq(c.chainName, "Zz Scratch Dynamic", "chainName");
        assertEq(c.chainNameIdentifier, SCRATCH_IDENTIFIER, "chainNameIdentifier");
        assertEq(c.chainFamily, "evm", "chainFamily");

        // parseChainName(identifier) -> chain ID
        assertEq(helperConfig.parseChainName(SCRATCH_IDENTIFIER), SCRATCH_CHAIN_ID, "parseChainName");

        // getDestChainConfig(identifier) and getChainNameBySelector(selector)
        assertEq(
            helperConfig.getDestChainConfig(SCRATCH_IDENTIFIER).chainSelector, SCRATCH_SELECTOR, "getDestChainConfig"
        );
        assertEq(helperConfig.getChainNameBySelector(SCRATCH_SELECTOR), "Zz Scratch Dynamic", "getChainNameBySelector");

        // getConfiguredChains() enumerates the new chain alongside the committed ones
        string[] memory chains = helperConfig.getConfiguredChains();
        bool foundScratch = false;
        bool foundSepolia = false;
        for (uint256 i = 0; i < chains.length; i++) {
            bytes32 h = keccak256(bytes(chains[i]));
            if (h == keccak256(bytes(SCRATCH_NAME))) foundScratch = true;
            if (h == keccak256(bytes("ethereum-testnet-sepolia"))) foundSepolia = true;
        }
        assertTrue(foundScratch, "scratch chain enumerated");
        assertTrue(foundSepolia, "committed chains still enumerated");
        _clean();
    }

    function test_UnknownChain_StillFailsExactlyAsBefore() public {
        // No scratch file for this case: behavior with only chains that are actually configured.
        HelperConfig helperConfig = new HelperConfig();

        vm.expectRevert(bytes("Unsupported chain ID"));
        helperConfig.getNetworkConfig(43113);

        vm.expectRevert(bytes("Invalid chain name"));
        helperConfig.parseChainName("AVALANCHE_FUJI");

        // Non-EVM identifiers resolve via the scan but still have no EVM chain ID.
        vm.expectRevert(bytes("Invalid chain name"));
        helperConfig.parseChainName("SOLANA_DEVNET");

        assertEq(helperConfig.getChainNameBySelector(1), "Unknown", "unknown selector");
        assertEq(helperConfig.getDestChainConfig("AVALANCHE_FUJI").chainFamily, "", "unknown dest zero config");
    }
}
