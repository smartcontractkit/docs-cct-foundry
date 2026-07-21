// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {DeploySafe} from "../../script/governance/DeploySafe.s.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {ISafe} from "../../src/base/ISafe.sol";
import {SafeBatchEmitter} from "../../src/base/SafeBatchEmitter.sol";
import {SafeBatchLoader} from "../../src/base/SafeBatchLoader.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

/// @notice Proofs for composing independently emitted Safe batches into ONE meta-transaction.
///         - The loader is the emitter's exact inverse (round-trip byte equality over the catalog).
///         - `loadMany` merges in the given order, and the merged calls equal the concatenation of
///           the per-operation builders - i.e. the calldata the EOA mode would broadcast.
///         - A full CCT setup (accept pool ownership + claim/accept registration pair + setPool +
///           applyChainUpdates) executes as ONE `execTransaction` consuming ONE Safe nonce, landing
///           the same pool/registry state as the sequential EOA path.
///         - Atomicity: a mis-ordered batch reverts as a whole with zero partial state.
///         - Composition guards: chain-id mismatch, foreign Safe, and empty batches are rejected.
///         - Gas: one merged meta-tx costs less than the same calls as separate Safe transactions
///           (in-EVM comparison; on-chain the saving is larger by N-1 avoided 21k intrinsic costs).
///
///         Env note: this suite reuses the exact env values `SafeModeForkTest` sets (same Safe, same
///         signer keys) and never writes `BATCH_NAME`/`SAFE_EXEC`, so it cannot race other suites'
///         env reads; the env-shell of `ExecuteBatch.s.sol` itself is exercised by the live run.
contract ExecuteBatchForkTest is BaseForkTest {
    uint256 internal constant OWNER1_KEY = 0xA11CE;
    uint256 internal constant OWNER2_KEY = 0xB0B;
    uint256 internal constant OWNER3_KEY = 0xC0FFEE;

    uint64 internal constant EVM_SELECTOR = 8236463271206331221; // Mantle Sepolia
    address internal constant EVM_REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant EVM_REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);

    address internal token;
    address internal pool;
    address internal deployer;
    ISafe internal safe;
    TokenAdminRegistry internal registry;
    address internal registryModule;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
        registry = TokenAdminRegistry(networkConfig.tokenAdminRegistry);
        registryModule = networkConfig.registryModuleOwnerCustom;

        // Identical values to SafeModeForkTest, so parallel suites see one consistent environment.
        vm.setEnv(
            "SAFE_OWNERS",
            string.concat(
                vm.toString(vm.addr(OWNER1_KEY)),
                ",",
                vm.toString(vm.addr(OWNER2_KEY)),
                ",",
                vm.toString(vm.addr(OWNER3_KEY))
            )
        );
        vm.setEnv("SAFE_THRESHOLD", "2");
        vm.setEnv("SAFE_SALT_NONCE", "0");
        safe = ISafe(new DeploySafe().run());
        vm.setEnv("SAFE_ADDRESS", vm.toString(address(safe)));
        vm.setEnv("SAFE_SIGNER_KEYS", string.concat(vm.toString(OWNER1_KEY), ",", vm.toString(OWNER2_KEY)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Loader == emitter⁻¹
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Round-trip over representative catalog shapes (1-call and 2-call batches): what the
    ///      emitter writes, the loader returns byte-identically.
    function test_Loader_RoundTripsEmitter() public {
        _assertRoundTrip(
            "p311-rt-pair", CctActions._registerAndAcceptAdminViaGetCCIPAdmin(registryModule, address(registry), token)
        );
        _assertRoundTrip("p311-rt-setpool", CctActions._setPool(address(registry), token, pool));
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        _assertRoundTrip("p311-rt-lane", CctActions._applyChainUpdates(pool, removes, updates));
        _assertRoundTrip("p311-rt-deposit", CctActions._lockboxDeposit(EVM_REMOTE_POOL, token, 1e18));
    }

    /// @dev `loadMany` merges in the given order and equals the concatenation of the builders -
    ///      the "merged inner calldata == concatenation of per-op EOA calldata" proof.
    function test_LoadMany_MergesInOrder() public {
        CctActions.Call[] memory pair =
            CctActions._registerAndAcceptAdminViaGetCCIPAdmin(registryModule, address(registry), token);
        CctActions.Call[] memory setPoolCall = CctActions._setPool(address(registry), token, pool);
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        CctActions.Call[] memory lane = CctActions._applyChainUpdates(pool, removes, updates);

        string[] memory paths = new string[](3);
        paths[0] = SafeMode._emitBatch("p311-merge-pair", address(safe), pair);
        paths[1] = SafeMode._emitBatch("p311-merge-setpool", address(safe), setPoolCall);
        paths[2] = SafeMode._emitBatch("p311-merge-lane", address(safe), lane);

        CctActions.Call[] memory merged = SafeBatchLoader._loadMany(paths, block.chainid, address(safe));
        CctActions.Call[] memory expected = CctActions._concat(CctActions._concat(pair, setPoolCall), lane);

        assertEq(merged.length, expected.length, "merged call count mismatch");
        for (uint256 i = 0; i < merged.length; i++) {
            assertEq(merged[i].target, expected[i].target, "merged target mismatch");
            assertEq(merged[i].value, expected[i].value, "merged value mismatch");
            assertEq(merged[i].data, expected[i].data, "merged calldata mismatch");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // One meta-transaction, one nonce, sequential-equal end state
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The full CCT setup as ONE Safe transaction: accept pool ownership, claim+accept the
    ///      registry administrator, setPool, applyChainUpdates - one `execTransaction`, one nonce.
    ///      The pool/registry end state must equal the sequential EOA path's.
    function test_MergedBatch_ModeB_FullSetup_OneNonce() public {
        // Sequential EOA reference (deployer does everything), captured on a snapshot.
        uint256 snapshot = vm.snapshotState();
        CctActions.Call[] memory eoaSetup = CctActions._concat(
            CctActions._registerAndAcceptAdminViaGetCCIPAdmin(registryModule, address(registry), token),
            CctActions._setPool(address(registry), token, pool)
        );
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        eoaSetup = CctActions._concat(eoaSetup, CctActions._applyChainUpdates(pool, removes, updates));
        _exec(deployer, eoaSetup);
        address eoaPool = registry.getPool(token);
        bytes memory eoaRemoteToken = TokenPool(pool).getRemoteToken(EVM_SELECTOR);
        vm.revertToState(snapshot);

        // Safe path: hand the token's CCIP admin and the pool's pending ownership to the Safe first
        // (the EOA-side prerequisites), then everything else happens in ONE Safe transaction.
        vm.prank(deployer);
        CrossChainToken(token).setCCIPAdmin(address(safe));
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(address(safe));

        string[] memory paths = new string[](4);
        paths[0] = SafeMode._emitBatch("p311-full-accept-own", address(safe), CctActions._acceptOwnership(pool));
        paths[1] = SafeMode._emitBatch(
            "p311-full-pair",
            address(safe),
            CctActions._registerAndAcceptAdminViaGetCCIPAdmin(registryModule, address(registry), token)
        );
        paths[2] = SafeMode._emitBatch(
            "p311-full-setpool", address(safe), CctActions._setPool(address(registry), token, pool)
        );
        paths[3] =
            SafeMode._emitBatch("p311-full-lane", address(safe), CctActions._applyChainUpdates(pool, removes, updates));

        CctActions.Call[] memory merged = SafeBatchLoader._loadMany(paths, block.chainid, address(safe));
        assertEq(merged.length, 5, "full setup must merge to five calls");

        uint256 nonceBefore = safe.nonce();
        SafeMode._execDirect(safe, merged);
        assertEq(safe.nonce(), nonceBefore + 1, "the whole setup must consume exactly ONE Safe nonce");

        assertEq(TokenPool(pool).owner(), address(safe), "Safe must own the pool");
        assertEq(registry.getTokenConfig(token).administrator, address(safe), "Safe must be the administrator");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(0), "pending must be cleared");
        assertEq(registry.getPool(token), eoaPool, "registry pool must equal the EOA path");
        assertEq(TokenPool(pool).getRemoteToken(EVM_SELECTOR), eoaRemoteToken, "lane config must equal the EOA path");
    }

    /// @dev Atomicity + ordering: the SAME two calls in the WRONG order (accept before claim) revert
    ///      the whole meta-transaction (GS013) and leave zero partial state.
    function test_MergedBatch_Atomicity_ReversedOrderReverts() public {
        vm.prank(deployer);
        CrossChainToken(token).setCCIPAdmin(address(safe));

        string[] memory paths = new string[](2);
        paths[0] = SafeMode._emitBatch(
            "p311-rev-accept", address(safe), CctActions._acceptAdminRole(address(registry), token)
        );
        paths[1] = SafeMode._emitBatch(
            "p311-rev-claim", address(safe), CctActions._registerAdminViaGetCCIPAdmin(registryModule, token)
        );
        CctActions.Call[] memory merged = SafeBatchLoader._loadMany(paths, block.chainid, address(safe));

        // expectRevert arms the next EXTERNAL call, so the internal library path goes through a shim.
        vm.expectRevert(bytes("GS013"));
        this.execDirectExternal(safe, merged);

        assertEq(registry.getTokenConfig(token).administrator, address(0), "no administrator may be set");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(0), "no pending admin may survive");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Composition guards
    // ─────────────────────────────────────────────────────────────────────────

    function test_Loader_RejectsChainIdMismatch() public {
        string memory path = "batches/p311-wrong-chain.json";
        SafeBatchEmitter._write(
            path, block.chainid + 1, address(safe), "p311-wrong-chain", "test", CctActions._acceptOwnership(pool)
        );
        vm.expectRevert();
        this.loadAndValidateExternal(path, block.chainid, address(safe));
    }

    function test_Loader_RejectsForeignSafe() public {
        string memory path = SafeMode._emitBatch("p311-foreign-safe", deployer, CctActions._acceptOwnership(pool));
        vm.expectRevert();
        this.loadAndValidateExternal(path, block.chainid, address(safe));
    }

    function test_Loader_RejectsEmptyBatch() public {
        string memory path = "batches/p311-empty.json";
        SafeBatchEmitter._write(path, block.chainid, address(safe), "p311-empty", "test", new CctActions.Call[](0));
        vm.expectRevert();
        this.loadAndValidateExternal(path, block.chainid, address(safe));
    }

    /// @dev external shim so expectRevert applies to the library call.
    function loadAndValidateExternal(string memory path, uint256 chainId, address expectedSafe)
        external
        view
        returns (CctActions.Call[] memory)
    {
        return SafeBatchLoader._loadAndValidate(path, chainId, expectedSafe);
    }

    /// @dev external shim so expectRevert applies to the whole Mode B execution.
    function execDirectExternal(ISafe execSafe, CctActions.Call[] memory calls) external {
        SafeMode._execDirect(execSafe, calls);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Gas: one merged meta-tx vs N separate Safe transactions
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The same three rate-limit updates executed (a) as three separate Safe transactions and
    ///      (b) as one merged meta-transaction, from the identical starting state. The merged run
    ///      must cost less in-EVM (it additionally saves N-1 x 21k intrinsic gas on-chain, which
    ///      this in-EVM measurement cannot see).
    function test_Gas_MergedVsSequential() public {
        // Prerequisite: lane configured, pool owned by the Safe.
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        _exec(deployer, CctActions._applyChainUpdates(pool, removes, updates));
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(address(safe));
        SafeMode._execDirect(safe, CctActions._acceptOwnership(pool));

        CctActions.Call[][] memory ops = new CctActions.Call[][](3);
        ops[0] = _rateLimitOp(200e18, 0.2e18);
        ops[1] = _rateLimitOp(300e18, 0.3e18);
        ops[2] = _rateLimitOp(400e18, 0.4e18);

        uint256 snapshot = vm.snapshotState();

        // (a) three separate Safe transactions.
        uint256 sequentialGas;
        for (uint256 i = 0; i < ops.length; i++) {
            uint256 before = gasleft();
            SafeMode._execDirect(safe, ops[i]);
            sequentialGas += before - gasleft();
        }
        (RateLimiter.TokenBucket memory sequentialState,) =
            TokenPool(pool).getCurrentRateLimiterState(EVM_SELECTOR, false);
        vm.revertToState(snapshot);

        // (b) one merged meta-transaction.
        CctActions.Call[] memory merged = CctActions._concat(CctActions._concat(ops[0], ops[1]), ops[2]);
        uint256 beforeMerged = gasleft();
        SafeMode._execDirect(safe, merged);
        uint256 mergedGas = beforeMerged - gasleft();
        (RateLimiter.TokenBucket memory mergedState,) = TokenPool(pool).getCurrentRateLimiterState(EVM_SELECTOR, false);

        emit log_named_uint("sequential Safe txs gas (in-EVM)", sequentialGas);
        emit log_named_uint("merged meta-tx gas (in-EVM)", mergedGas);
        assertLt(mergedGas, sequentialGas, "one merged meta-tx must cost less than N separate Safe txs");
        assertEq(mergedState.capacity, sequentialState.capacity, "both paths must land the same final state");
        assertEq(mergedState.rate, sequentialState.rate, "both paths must land the same final state");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _assertRoundTrip(string memory name, CctActions.Call[] memory calls) internal {
        string memory path = SafeMode._emitBatch(name, address(safe), calls);
        (uint256 chainId, address batchSafe, CctActions.Call[] memory loaded) = SafeBatchLoader._load(path);
        assertEq(chainId, block.chainid, string.concat(name, ": chainId mismatch"));
        assertEq(batchSafe, address(safe), string.concat(name, ": safe mismatch"));
        assertEq(loaded.length, calls.length, string.concat(name, ": call count mismatch"));
        for (uint256 i = 0; i < calls.length; i++) {
            assertEq(loaded[i].target, calls[i].target, string.concat(name, ": target mismatch"));
            assertEq(loaded[i].value, calls[i].value, string.concat(name, ": value mismatch"));
            assertEq(loaded[i].data, calls[i].data, string.concat(name, ": data mismatch"));
        }
    }

    function _rateLimitOp(uint128 capacity, uint128 rate) internal view returns (CctActions.Call[] memory) {
        return CctActions._setRateLimits(
            pool,
            PoolVersions.Version.V2_0_0,
            EVM_SELECTOR,
            false,
            RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate}),
            RateLimiter.Config({isEnabled: true, capacity: capacity / 2, rate: rate / 2})
        );
    }

    function _laneInput() internal pure returns (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) {
        removes = new uint64[](0);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(EVM_REMOTE_POOL);
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: EVM_SELECTOR,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(EVM_REMOTE_TOKEN),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
    }
}
