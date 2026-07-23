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

    // Divergence-notice fixture: the ARBITRUM lane, which project/ethereum-testnet-sepolia.json (the
    // fork's local chain) DECLARES a non-zero rate limit for (capacity 100000e18, rate 100e18). Only a
    // declared lane drives the notice's compare/print branches; the other phases target undeclared
    // chains and early-return. The DIVERGENT_* values deliberately differ from that declaration.
    string internal constant ARBITRUM_ID = "ETHEREUM_TESTNET_SEPOLIA_ARBITRUM_1";
    uint64 internal constant ARBITRUM_SELECTOR = 3478487238524512106;
    uint128 internal constant DIVERGENT_CAPACITY = 5_000e18;
    uint128 internal constant DIVERGENT_RATE = 5e18;

    // SVM destination expectations. The raw 32-byte values are derived from an
    // INDEPENDENT base58 decode (Python), not from the code under test.
    string internal constant SVM_REMOTE_POOL = "3emsAVdmGKERbHjmGfQ6oZ1e35dkf5iYcS6U4CPKFVaa";
    bytes internal constant SVM_REMOTE_POOL_BYTES =
        hex"276497ba0bb8659172b72edd8c66e18f561764d9c86a610a3a7e0f79c0baf9db";
    string internal constant SVM_REMOTE_TOKEN = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    bytes internal constant SVM_REMOTE_TOKEN_BYTES =
        hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61";

    // Aptos destination. Aptos accounts are 32-byte hex addresses; the expected bytes are the address
    // hex parsed directly (the encoder left-pads short forms, unit-tested in ChainHandlers.t.sol). The
    // entry carries an explicit destChainSelector + destChainFamily so no aptos config file is required.
    uint64 internal constant APTOS_SELECTOR = 743186221051783445; // aptos-testnet (chain-selectors)
    string internal constant APTOS_REMOTE_POOL = "0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa";
    bytes internal constant APTOS_REMOTE_POOL_BYTES =
        hex"f22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa";
    string internal constant APTOS_REMOTE_TOKEN = "0xa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
    bytes internal constant APTOS_REMOTE_TOKEN_BYTES =
        hex"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    /// @dev The example's first entry holds the lowest placeholder, so it is the one the guard names.
    string internal constant PLACEHOLDER_REJECTION = "remoteChains[0].destToken is still the template placeholder 0x0000000000000000000000000000000000000002"
        " - replace every destPools/destToken entry in the input file with the deployed addresses.";

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
        _assertAptosDestinationConfigured();

        // Second phase in the SAME test (forge runs tests in parallel, and both phases rewrite the
        // script's fixed input path - separate tests would race on the file): the COMMITTED example.
        vm.revertToState(cleanState);
        _runCommittedExample();

        // Third phase: idempotent RE-APPLY against an already-configured selector. The other phases
        // run against a fresh pool, so the script's `shouldRemove[i] = isSupportedChain(selector)`
        // gate is always false and its remove-then-re-add branch is never taken. This runs the script
        // TWICE for the same selector: the second run must hit that gate, remove, and re-add without
        // reverting `ChainAlreadyExists`. A regression in that gate (inverted or dropped) fails here.
        vm.revertToState(cleanState);
        _runIdempotentReApply();

        // Fourth phase: the rate-limit DIVERGENCE NOTICE branches, on a DECLARED lane (ARBITRUM) so the
        // notice's compare/print logic actually runs instead of early-returning. Asserts the notice
        // never reverts the apply and never overrides the file (JSON mode stays file-authoritative).
        vm.revertToState(cleanState);
        _runDivergenceNoticePaths();
    }

    /// @notice Runs the script twice for MANTLE_SEPOLIA: first with remote pool 1, then with remote
    ///         pool 2. The second run exercises the `isSupportedChain==true` removes branch end to end.
    function _runIdempotentReApply() internal {
        uint64 selector = helperConfig.getMantleSepoliaConfig().chainSelector;
        string memory originalInput = vm.readFile(INPUT_PATH);
        vm.setEnv("VIA_JSON_FILE", "true");

        vm.writeFile(INPUT_PATH, _buildSingleEvmInput(EVM_REMOTE_POOL_1));
        new ApplyChainUpdates().run();
        assertTrue(pool.isSupportedChain(selector), "re-apply: first run did not configure the selector");
        assertTrue(pool.isRemotePool(selector, abi.encode(EVM_REMOTE_POOL_1)), "re-apply: pool 1 not registered");

        // Second run for the SAME selector, now supported: must remove-then-re-add, not revert.
        vm.writeFile(INPUT_PATH, _buildSingleEvmInput(EVM_REMOTE_POOL_2));
        new ApplyChainUpdates().run();

        vm.setEnv("VIA_JSON_FILE", "false");
        vm.writeFile(INPUT_PATH, originalInput);

        assertTrue(pool.isSupportedChain(selector), "re-apply: selector unsupported after re-apply");
        assertEq(pool.getRemotePools(selector).length, 1, "re-apply: replace-not-merge, expected one remote");
        assertTrue(pool.isRemotePool(selector, abi.encode(EVM_REMOTE_POOL_2)), "re-apply: pool 2 not registered");
        assertFalse(pool.isRemotePool(selector, abi.encode(EVM_REMOTE_POOL_1)), "re-apply: pool 1 not replaced");
    }

    /// @dev A single-EVM input for the ARBITRUM lane. `omitOutbound=true` drops the outboundRateLimit
    ///      block entirely (drives the notice's omitted branch); otherwise the block is written with
    ///      (outCap, outRate) - the contradicting branch when those differ from the declaration. Inbound
    ///      is always an explicit disabled block so only the outbound direction is under test.
    function _buildArbitrumInput(bool omitOutbound, uint256 outCap, uint256 outRate)
        internal
        view
        returns (string memory)
    {
        string memory head = string.concat(
            '{"sourcePool":"',
            vm.toString(address(pool)),
            '","remoteChains":[{"destChain":"',
            ARBITRUM_ID,
            '","destPools":["',
            vm.toString(EVM_REMOTE_POOL_1),
            '"],"destToken":"',
            vm.toString(EVM_REMOTE_TOKEN),
            '"'
        );
        string memory tail = omitOutbound
            ? ',"inboundRateLimit":{"enabled":false,"capacity":0,"rate":0}}]}'
            : string.concat(
                ',"outboundRateLimit":{"enabled":true,"capacity":',
                vm.toString(outCap),
                ',"rate":',
                vm.toString(outRate),
                '},"inboundRateLimit":{"enabled":false,"capacity":0,"rate":0}}]}'
            );
        return string.concat(head, tail);
    }

    /// @notice Drives the JSON-mode rate-limit DIVERGENCE NOTICE on a DECLARED lane (ARBITRUM). The other
    ///         phases target chains the Sepolia project store does not declare, so the notice
    ///         (`_noticeJsonRateLimitDivergence`) early-returns and its compare/print branches never run.
    ///         This phase runs them. The notice is a build-time console line that cannot be asserted
    ///         directly; what is load-bearing and IS asserted: it never reverts the apply, and JSON mode
    ///         stays file-authoritative (the notice never overrides the file with the declared value).
    function _runDivergenceNoticePaths() internal {
        string memory originalInput = vm.readFile(INPUT_PATH);
        vm.setEnv("VIA_JSON_FILE", "true");

        // Omitted branch: no outboundRateLimit, but lanes{} declares one. The apply must succeed and,
        // being file-authoritative, leave outbound DISABLED - it must NOT fall back to the declaration.
        vm.writeFile(INPUT_PATH, _buildArbitrumInput(true, 0, 0));
        new ApplyChainUpdates().run();
        assertTrue(pool.isSupportedChain(ARBITRUM_SELECTOR), "divergence(omit): lane not configured");
        (RateLimiter.TokenBucket memory outOmit,) = pool.getCurrentRateLimiterState(ARBITRUM_SELECTOR, false);
        assertFalse(outOmit.isEnabled, "divergence(omit): omitted block must apply DISABLED, not lanes{} fallback");

        // Contradicting branch: an explicit outbound differing from the declared limit. The apply must
        // write the FILE's value, not the declaration.
        vm.writeFile(INPUT_PATH, _buildArbitrumInput(false, DIVERGENT_CAPACITY, DIVERGENT_RATE));
        new ApplyChainUpdates().run();
        (RateLimiter.TokenBucket memory outDiff,) = pool.getCurrentRateLimiterState(ARBITRUM_SELECTOR, false);
        assertTrue(outDiff.isEnabled, "divergence(contradict): outbound should be enabled from the file");
        assertEq(outDiff.capacity, DIVERGENT_CAPACITY, "divergence(contradict): file capacity must win over lanes{}");
        assertEq(outDiff.rate, DIVERGENT_RATE, "divergence(contradict): file rate must win over lanes{}");

        vm.setEnv("VIA_JSON_FILE", "false");
        vm.writeFile(INPUT_PATH, originalInput);
    }

    /// @dev A one-EVM-destination input for MANTLE_SEPOLIA carrying a single remote pool.
    function _buildSingleEvmInput(address remotePool) internal view returns (string memory) {
        return string.concat(
            '{"sourcePool":"',
            vm.toString(address(pool)),
            '","remoteChains":[{"destChain":"MANTLE_SEPOLIA","destPools":["',
            vm.toString(remotePool),
            '"],"destToken":"',
            vm.toString(EVM_REMOTE_TOKEN),
            '","outboundRateLimit":{"enabled":false,"capacity":0,"rate":0},',
            '"inboundRateLimit":{"enabled":false,"capacity":0,"rate":0}}]}'
        );
    }

    /// @dev Fills the example's EVM placeholders with the fixture's remote addresses, leaving its
    ///      chains, pool counts, and rate limits intact - the second half of the phase still runs the
    ///      shipped file's shape. The SVM entry keeps its base58 keys: the guard is EVM-only.
    function _replaceExamplePlaceholders() internal {
        string memory json = vm.readFile(INPUT_PATH);
        json = vm.replace(json, "0x0000000000000000000000000000000000000001", vm.toString(EVM_REMOTE_POOL_1));
        json = vm.replace(json, "0x0000000000000000000000000000000000000002", vm.toString(EVM_REMOTE_TOKEN));
        // The second entry declares TWO remote pools; they must stay distinct so the count assertion
        // below still proves both were registered rather than deduplicated into one.
        json = vm.replace(json, "0x0000000000000000000000000000000000000003", vm.toString(EVM_REMOTE_POOL_1));
        json = vm.replace(json, "0x0000000000000000000000000000000000000004", vm.toString(EVM_REMOTE_POOL_2));
        json = vm.replace(json, "0x0000000000000000000000000000000000000005", vm.toString(EVM_REMOTE_TOKEN));
        vm.writeFile(INPUT_PATH, json);
    }

    /// @notice JSON mode with the COMMITTED example file (not a test fixture): every `destChain` it
    ///         names must resolve through HelperConfig so the example runs clean as shipped. Only the
    ///         deployment-specific `sourcePool` field is pointed at the test fixture pool.
    /// @dev Two halves. First: replacing ONLY `sourcePool` - the file's first field, and the edit an
    ///      operator makes before noticing the rest - must be REJECTED. Left unguarded that run
    ///      succeeds and registers real lanes on the real pool pointing at addresses holding no
    ///      pool: a batch that executes cleanly and leaves a dead lane, found later on a failing
    ///      transfer. Second: with the placeholders also replaced, the example applies as shipped,
    ///      which is the schema/`destChain`-resolution regression guard this phase was written for.
    function _runCommittedExample() internal {
        string memory originalInput = vm.readFile(INPUT_PATH);
        vm.writeJson(string.concat("\"", vm.toString(address(pool)), "\""), INPUT_PATH, ".sourcePool");
        vm.setEnv("VIA_JSON_FILE", "true");

        ApplyChainUpdates partiallyEdited = new ApplyChainUpdates();
        vm.expectRevert(bytes(PLACEHOLDER_REJECTION));
        partiallyEdited.run();

        _replaceExamplePlaceholders();
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
        // Split into per-entry sub-concats: one flat string.concat over all three entries exceeds the
        // 16-slot stack limit.
        string memory evmEntry = string.concat(
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
            '},"inboundRateLimit":{"enabled":false,"capacity":0,"rate":0}}'
        );
        string memory svmEntry = string.concat(
            '{"destChain":"SOLANA_DEVNET","destPools":["', SVM_REMOTE_POOL, '"],"destToken":"', SVM_REMOTE_TOKEN, '"}'
        );
        string memory aptosEntry = string.concat(
            '{"destChain":"APTOS_TESTNET","destChainFamily":"aptos","destChainSelector":',
            vm.toString(APTOS_SELECTOR),
            ',"destPools":["',
            APTOS_REMOTE_POOL,
            '"],"destToken":"',
            APTOS_REMOTE_TOKEN,
            '"}'
        );
        return string.concat(
            '{"sourcePool":"',
            vm.toString(address(pool)),
            '","remoteChains":[',
            evmEntry,
            ",",
            svmEntry,
            ",",
            aptosEntry,
            "]}"
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

    function _assertAptosDestinationConfigured() internal view {
        assertTrue(pool.isSupportedChain(APTOS_SELECTOR), "Aptos destination not supported");

        // Aptos addresses must byte-match the raw 32-byte hex-parsed account addresses.
        bytes[] memory remotePools = pool.getRemotePools(APTOS_SELECTOR);
        assertEq(remotePools.length, 1, "unexpected Aptos remote pool count");
        assertEq(remotePools[0], APTOS_REMOTE_POOL_BYTES, "Aptos remote pool bytes mismatch");
        assertEq(pool.getRemoteToken(APTOS_SELECTOR), APTOS_REMOTE_TOKEN_BYTES, "Aptos remote token bytes mismatch");
    }
}
