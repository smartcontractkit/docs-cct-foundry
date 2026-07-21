// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {ApplyChainUpdates} from "../../script/setup/ApplyChainUpdates.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork test for script/setup/ApplyChainUpdates.s.sol in JSON-file mode
/// (VIA_JSON_FILE=true). The test writes a config for one EVM destination (two remote
/// pools + rate limits) and one SVM destination (Solana devnet base58 addresses) to the
/// script's fixed input path, runs the script against the fixture pool, restores the
/// original input file, and asserts the on-chain pool config byte-matches the input.
contract ApplyChainUpdatesForkTest is BaseForkTest {
    string internal constant INPUT_PATH = "script/input/apply-chain-updates.json";

    // EVM destination expectations.
    address internal constant EVM_REMOTE_POOL_1 = address(0x1111111111111111111111111111111111111111);
    address internal constant EVM_REMOTE_POOL_2 = address(0x2222222222222222222222222222222222222222);
    address internal constant EVM_REMOTE_TOKEN = address(0x3333333333333333333333333333333333333333);
    uint128 internal constant OUTBOUND_CAPACITY = 1_000e18;
    uint128 internal constant OUTBOUND_RATE = 0.1e18;

    // SVM destination expectations. The raw 32-byte values are derived from an
    // INDEPENDENT base58 decode (Python), not from the code under test.
    string internal constant SVM_REMOTE_POOL = "3emsAVdmGKERbHjmGfQ6oZ1e35dkf5iYcS6U4CPKFVaa";
    bytes internal constant SVM_REMOTE_POOL_BYTES =
        hex"276497ba0bb8659172b72edd8c66e18f561764d9c86a610a3a7e0f79c0baf9db";
    string internal constant SVM_REMOTE_TOKEN = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    bytes internal constant SVM_REMOTE_TOKEN_BYTES =
        hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61";

    TokenPool internal pool;

    function setUp() public override {
        super.setUp();
        (, address poolAddress) = deployTokenAndPoolFixture();
        pool = TokenPool(poolAddress);
    }

    function test_ApplyChainUpdates_ViaJsonFile() public {
        // The script reads a fixed input path; back up the committed example and restore it
        // after the run so the working tree is left untouched.
        uint256 cleanState = vm.snapshotState();
        string memory originalInput = vm.readFile(INPUT_PATH);
        vm.writeFile(INPUT_PATH, _buildInputJson());
        vm.setEnv("VIA_JSON_FILE", "true");

        new ApplyChainUpdates().run();

        vm.setEnv("VIA_JSON_FILE", "false");
        vm.writeFile(INPUT_PATH, originalInput);

        _assertEvmDestinationConfigured();
        _assertSvmDestinationConfigured();

        // Second phase in the SAME test (forge runs tests in parallel, and both phases rewrite the
        // script's fixed input path - separate tests would race on the file): the COMMITTED example.
        vm.revertToState(cleanState);
        _runCommittedExample();
    }

    /// @notice JSON mode with the COMMITTED example file (not a test fixture): every `destChain` it
    ///         names must resolve through HelperConfig so the example runs clean as shipped. Only the
    ///         deployment-specific `sourcePool` field is pointed at the test fixture pool.
    function _runCommittedExample() internal {
        string memory originalInput = vm.readFile(INPUT_PATH);
        vm.writeJson(string.concat("\"", vm.toString(address(pool)), "\""), INPUT_PATH, ".sourcePool");
        vm.setEnv("VIA_JSON_FILE", "true");

        new ApplyChainUpdates().run();

        vm.setEnv("VIA_JSON_FILE", "false");
        vm.writeFile(INPUT_PATH, originalInput);

        // The committed example configures MANTLE_SEPOLIA, PLUME_TESTNET, and SOLANA_DEVNET.
        assertTrue(
            pool.isSupportedChain(helperConfig.getMantleSepoliaConfig().chainSelector),
            "committed example: Mantle Sepolia not configured"
        );
        assertTrue(
            pool.isSupportedChain(helperConfig.getPlumeTestnetConfig().chainSelector),
            "committed example: Plume Testnet not configured"
        );
        assertTrue(
            pool.isSupportedChain(helperConfig.getSolanaDevnetConfig().chainSelector),
            "committed example: Solana Devnet not configured"
        );
        // The example's second entry carries two remote pools - both must be registered.
        assertEq(
            pool.getRemotePools(helperConfig.getPlumeTestnetConfig().chainSelector).length,
            2,
            "committed example: Plume remote pool count mismatch"
        );
    }

    function _buildInputJson() internal view returns (string memory) {
        return string.concat(
            '{"sourcePool":"',
            vm.toString(address(pool)),
            '","remoteChains":[',
            '{"destChain":"MANTLE_SEPOLIA","destPools":["',
            vm.toString(EVM_REMOTE_POOL_1),
            '","',
            vm.toString(EVM_REMOTE_POOL_2),
            '"],"destToken":"',
            vm.toString(EVM_REMOTE_TOKEN),
            '","outboundRateLimit":{"enabled":true,"capacity":',
            vm.toString(uint256(OUTBOUND_CAPACITY)),
            ',"rate":',
            vm.toString(uint256(OUTBOUND_RATE)),
            '},"inboundRateLimit":{"enabled":false,"capacity":0,"rate":0}},',
            '{"destChain":"SOLANA_DEVNET","destPools":["',
            SVM_REMOTE_POOL,
            '"],"destToken":"',
            SVM_REMOTE_TOKEN,
            '"}]}'
        );
    }

    function _assertEvmDestinationConfigured() internal view {
        uint64 selector = helperConfig.getMantleSepoliaConfig().chainSelector;
        assertTrue(pool.isSupportedChain(selector), "EVM destination not supported");

        // Remote pools must byte-match abi.encode(address) for every pool in the input file.
        bytes[] memory remotePools = pool.getRemotePools(selector);
        assertEq(remotePools.length, 2, "unexpected EVM remote pool count");
        assertTrue(pool.isRemotePool(selector, abi.encode(EVM_REMOTE_POOL_1)), "EVM remote pool 1 missing");
        assertTrue(pool.isRemotePool(selector, abi.encode(EVM_REMOTE_POOL_2)), "EVM remote pool 2 missing");
        assertEq(pool.getRemoteToken(selector), abi.encode(EVM_REMOTE_TOKEN), "EVM remote token mismatch");

        (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) =
            pool.getCurrentRateLimiterState(selector, false);
        assertTrue(outbound.isEnabled, "outbound rate limit not enabled");
        assertEq(outbound.capacity, OUTBOUND_CAPACITY, "outbound capacity mismatch");
        assertEq(outbound.rate, OUTBOUND_RATE, "outbound rate mismatch");
        assertFalse(inbound.isEnabled, "inbound rate limit unexpectedly enabled");
    }

    function _assertSvmDestinationConfigured() internal view {
        uint64 selector = helperConfig.getSolanaDevnetConfig().chainSelector;
        assertTrue(pool.isSupportedChain(selector), "SVM destination not supported");

        // SVM addresses must byte-match the raw 32-byte base58-decoded public keys.
        bytes[] memory remotePools = pool.getRemotePools(selector);
        assertEq(remotePools.length, 1, "unexpected SVM remote pool count");
        assertEq(remotePools[0], SVM_REMOTE_POOL_BYTES, "SVM remote pool bytes mismatch");
        assertEq(pool.getRemoteToken(selector), SVM_REMOTE_TOKEN_BYTES, "SVM remote token bytes mismatch");
    }
}
