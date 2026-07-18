// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {AccessControlOnlyToken} from "../fixtures/ClaimPathMocks.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {DeploySafe} from "../../script/governance/DeploySafe.s.sol";
import {AcceptAdminRole} from "../../script/setup/AcceptAdminRole.s.sol";
import {CctActions, ITokenPoolV150, ILockReleaseV1Liquidity} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {EoaExecutor} from "../../src/base/EoaExecutor.s.sol";
import {ISafe, SafeCanonical} from "../../src/base/ISafe.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

/// @dev Test-only: the real AcceptAdminRole script pinned to safe mode via the override (the `MODE`
///      env var is process-wide, see ExecutorHarness). Captures the built calls instead of
///      emitting/broadcasting, so parallel tests never contend on batch files.
contract AcceptAdminRoleSafeHarness is AcceptAdminRole {
    CctActions.Call[] public captured;

    function _executionMode() internal pure override returns (string memory) {
        return "safe";
    }

    function executeCalls(CctActions.Call[] memory calls) internal override {
        for (uint256 i = 0; i < calls.length; i++) {
            captured.push(calls[i]);
        }
    }

    function capturedCount() external view returns (uint256) {
        return captured.length;
    }
}

/// @dev Test-only executor harness: pins the execution mode via an override instead of the `MODE`
///      environment variable, because `vm.setEnv` is process-wide and forge runs test contracts in
///      parallel — flipping `MODE` in the environment would leak into every other suite's script runs.
contract ExecutorHarness is EoaExecutor {
    string private s_mode;

    constructor(string memory mode) {
        s_mode = mode;
    }

    function exec(CctActions.Call[] memory calls) external {
        executeCalls(calls);
    }

    function _executionMode() internal view override returns (string memory) {
        return s_mode;
    }
}

/// @dev Test-only minimal v1.x LockRelease pool: mirrors the `ILockReleaseV1Liquidity` surface the action
///      layer targets (the real v1.x LockRelease pool is NOT in the vendored 2.0.0 package, so a shim stands
///      in for it exactly like `ILockReleaseV1Liquidity` itself). `provideLiquidity` pulls tokens via
///      `transferFrom`, so the caller (the rebalancer — here the Safe) must have approved this pool first;
///      the two happen in ONE Safe MultiSend, which is precisely what the flow test proves.
contract MockLockReleaseV1Pool {
    IERC20 private immutable i_token;
    address private s_rebalancer;

    constructor(IERC20 token_) {
        i_token = token_;
    }

    function getToken() external view returns (IERC20) {
        return i_token;
    }

    function getRebalancer() external view returns (address) {
        return s_rebalancer;
    }

    function setRebalancer(address rebalancer) external {
        s_rebalancer = rebalancer;
    }

    function provideLiquidity(uint256 amount) external {
        require(msg.sender == s_rebalancer, "MockLockRelease: caller is not the rebalancer");
        require(i_token.transferFrom(msg.sender, address(this), amount), "MockLockRelease: transferFrom failed");
    }

    function withdrawLiquidity(uint256 amount) external {
        require(msg.sender == s_rebalancer, "MockLockRelease: caller is not the rebalancer");
        require(i_token.transfer(msg.sender, amount), "MockLockRelease: transfer failed");
    }
}

/// @notice Safe-mode proofs against a real Safe deployed from the
///         canonical v1.4.1 stack on a Sepolia fork:
///         - Requirement 2 byte-equality: for the whole action-layer catalog, the Safe Transaction
///           Builder batch JSON and the Mode B `execTransaction` payload carry the IDENTICAL inner
///           `to`/`value`/`data` the EOA mode broadcasts.
///         - Mode B end-to-end: build → hash (local recompute == on-chain) → sign → pack sorted →
///           `execTransaction` → the resulting on-chain state equals the EOA path's end state.
///         - The claim+accept registration pair executes atomically as ONE Safe batch.
///         - The `MODE` switch dispatches correctly and rejects unknown modes.
contract SafeModeForkTest is BaseForkTest {
    uint256 internal constant OWNER1_KEY = 0xA11CE;
    uint256 internal constant OWNER2_KEY = 0xB0B;
    uint256 internal constant OWNER3_KEY = 0xC0FFEE;

    // Fixed lane-config inputs (EVM remote), matching the SetupActions parity fixtures.
    uint64 internal constant EVM_SELECTOR = 8236463271206331221; // Mantle Sepolia
    address internal constant EVM_REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant EVM_REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);

    address internal token;
    address internal pool;
    address internal deployer;
    ISafe internal safe;
    TokenAdminRegistry internal registry;
    RegistryModuleOwnerCustom internal registryModule;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
        registry = TokenAdminRegistry(networkConfig.tokenAdminRegistry);
        registryModule = RegistryModuleOwnerCustom(networkConfig.registryModuleOwnerCustom);

        // Deploy the governed Safe (2-of-3) from the canonical v1.4.1 stack. All values are constant,
        // so the CREATE2 address — and therefore every env var below — is identical across parallel
        // suites (the same reasoning the fixture env vars rely on).
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
        // Two of the three owner keys — meets the threshold. Test-only keys, never real secrets.
        vm.setEnv("SAFE_SIGNER_KEYS", string.concat(vm.toString(OWNER1_KEY), ",", vm.toString(OWNER2_KEY)));
        vm.setEnv("SAFE_EXEC", "");
        vm.setEnv("BATCH_NAME", "test-dispatch");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MODE switch dispatch
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Default mode broadcasts exactly as before the switch existed: the call lands on-chain from
    ///      the script signer.
    function test_ModeEoa_BroadcastsCalls() public {
        ExecutorHarness harness = new ExecutorHarness("eoa");
        harness.exec(CctActions.registerAdminViaGetCCIPAdmin(address(registryModule), token));
        assertEq(
            registry.getTokenConfig(token).pendingAdministrator,
            deployer,
            "eoa mode must broadcast the claim from the script signer"
        );
    }

    /// @dev Safe mode must NOT broadcast the inner calls; it emits the batch for review instead. This
    ///      is the only test that drives the env-reading `SafeMode.run` path (via the dispatch), so the
    ///      `BATCH_NAME` set in setUp is race-free; the other tests pass parameters directly.
    function test_ModeSafe_EmitsBatchWithoutBroadcasting() public {
        ExecutorHarness harness = new ExecutorHarness("safe");
        harness.exec(CctActions.registerAdminViaGetCCIPAdmin(address(registryModule), token));
        assertEq(
            registry.getTokenConfig(token).pendingAdministrator,
            address(0),
            "safe mode must not broadcast the inner call"
        );
        string memory json = vm.readFile(string.concat("batches/test-dispatch.", vm.toString(block.chainid), ".json"));
        assertEq(
            vm.parseJsonAddress(json, ".transactions[0].to"),
            address(registryModule),
            "emitted batch must target the registry module"
        );
    }

    function test_ModeUnknown_Reverts() public {
        ExecutorHarness harness = new ExecutorHarness("timelock");
        vm.expectRevert(bytes("Unknown MODE 'timelock': use 'eoa' (default) or 'safe'."));
        harness.exec(CctActions.acceptAdminRole(address(registry), token));
    }

    /// @dev AcceptAdminRole's preflight compares the pending administrator against the account
    ///      executing in the selected mode — the Safe in safe mode, the broadcaster otherwise. With
    ///      the Safe pending, a safe-mode run passes preflight and builds the accept call; the
    ///      EOA-mode preflight still rejects a broadcaster that is not the pending administrator.
    function test_AcceptAdminRole_SafeMode_PreflightUsesExecutingAccount() public {
        // Make the Safe the pending administrator (claim executed by the Safe).
        vm.prank(deployer);
        CrossChainToken(token).setCCIPAdmin(address(safe));
        _runSafeDirect("safe-claim", CctActions.registerAdminViaGetCCIPAdmin(address(registryModule), token));
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(safe), "Safe must be pending");

        // Safe-mode run passes preflight and builds the accept call (captured, not broadcast).
        AcceptAdminRoleSafeHarness harness = new AcceptAdminRoleSafeHarness();
        harness.run();
        assertEq(harness.capturedCount(), 1, "safe-mode AcceptAdminRole must build the accept call");
        (address target,, bytes memory data) = harness.captured(0);
        assertEq(target, address(registry), "accept must target the TokenAdminRegistry");
        assertEq(
            data,
            abi.encodeCall(TokenAdminRegistry.acceptAdminRole, (token)),
            "accept calldata must match the action layer"
        );

        // EOA-mode preflight unchanged: the broadcaster is not the pending administrator -> revert.
        AcceptAdminRole eoaScript = new AcceptAdminRole();
        vm.expectRevert(bytes("Only the pending administrator can accept the admin role"));
        eoaScript.run();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Requirement 2: byte-equality over the action-layer catalog
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev For EVERY builder in the action-layer catalog: the Safe Transaction Builder JSON round-trips
    ///      to the IDENTICAL `to`/`value`/`data` the EOA mode would broadcast, and the Mode B
    ///      `execTransaction` payload (single-call passthrough or MultiSend packing) decodes back to the
    ///      same bytes. The `Call[]` IS what `EoaExecutor` broadcasts, so equality here is equality with
    ///      the EOA calldata.
    function test_ByteEquality_SetupCatalog() public {
        _assertBatchRoundTrip(
            "register-admin-via-owner", CctActions.registerAdminViaOwner(address(registryModule), token)
        );
        _assertBatchRoundTrip(
            "register-admin-via-getccipadmin", CctActions.registerAdminViaGetCCIPAdmin(address(registryModule), token)
        );
        _assertBatchRoundTrip("accept-admin-role", CctActions.acceptAdminRole(address(registry), token));
        _assertBatchRoundTrip(
            "registration-pair-via-owner",
            CctActions.registerAndAcceptAdminViaOwner(address(registryModule), address(registry), token)
        );
        _assertBatchRoundTrip(
            "registration-pair-via-getccipadmin",
            CctActions.registerAndAcceptAdminViaGetCCIPAdmin(address(registryModule), address(registry), token)
        );
        _assertBatchRoundTrip(
            "register-admin-via-access-control",
            CctActions.registerAccessControlDefaultAdmin(address(registryModule), token)
        );
        _assertBatchRoundTrip(
            "registration-pair-via-access-control",
            CctActions.registerAndAcceptAdminViaAccessControl(address(registryModule), address(registry), token)
        );
        _assertBatchRoundTrip("set-pool", CctActions.setPool(address(registry), token, pool));
        _assertBatchRoundTrip(
            "transfer-admin-role", CctActions.transferAdminRole(address(registry), token, address(safe))
        );
        _assertBatchRoundTrip("transfer-ownership", CctActions.transferOwnership(pool, address(safe)));
        _assertBatchRoundTrip("accept-ownership", CctActions.acceptOwnership(pool));
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        _assertBatchRoundTrip("apply-chain-updates", CctActions.applyChainUpdates(pool, removes, updates));
    }

    function test_ByteEquality_ConfigureAndOperationsCatalog() public {
        RateLimiter.Config memory outbound = RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18});
        RateLimiter.Config memory inbound = RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
        _assertBatchRoundTrip(
            "set-rate-limits-v2",
            CctActions.setRateLimits(pool, PoolVersions.Version.V2_0_0, EVM_SELECTOR, false, outbound, inbound)
        );
        _assertBatchRoundTrip(
            "set-rate-limits-v1",
            CctActions.setRateLimits(pool, PoolVersions.Version.V1_6_1, EVM_SELECTOR, false, outbound, inbound)
        );
        _assertBatchRoundTrip(
            "set-dynamic-config", CctActions.setDynamicConfig(pool, networkConfig.router, deployer, deployer)
        );
        _assertBatchRoundTrip(
            "add-remote-pool", CctActions.addRemotePool(pool, EVM_SELECTOR, abi.encode(EVM_REMOTE_POOL))
        );
        _assertBatchRoundTrip(
            "remove-remote-pool", CctActions.removeRemotePool(pool, EVM_SELECTOR, abi.encode(EVM_REMOTE_POOL))
        );
        address[] memory adds = new address[](1);
        adds[0] = deployer;
        address[] memory removals = new address[](0);
        _assertBatchRoundTrip("apply-allowlist-updates", CctActions.applyAllowListUpdates(pool, removals, adds));
        _assertBatchRoundTrip(
            "apply-authorized-caller-updates", CctActions.applyAuthorizedCallerUpdates(pool, adds, removals)
        );
        _assertBatchRoundTrip("mint", CctActions.mint(token, deployer, 1e18));
        _assertBatchRoundTrip("lockbox-deposit", CctActions.lockboxDeposit(EVM_REMOTE_POOL, token, 1e18));
        _assertBatchRoundTrip("lockbox-withdraw", CctActions.lockboxWithdraw(EVM_REMOTE_POOL, token, 1e18, deployer));
        address[] memory feeTokens = new address[](1);
        feeTokens[0] = token;
        _assertBatchRoundTrip("withdraw-fee-tokens", CctActions.withdrawFeeTokens(pool, feeTokens, deployer));
    }

    /// @dev PR #9 (lanes-as-data / version-dispatched pool ops / CCV config / v1.x LockRelease liquidity /
    ///      1.5.0 lane shape) added six new action-layer builders. The byte-equality contract is "for EVERY
    ///      builder in the catalog", so every new builder must round-trip identically under Safe — this
    ///      extends the catalog to cover them. Targets are the fixture pool (a plausible target address is
    ///      all byte-equality needs; these builders are never executed here, only encoded and round-tripped).
    function test_ByteEquality_VersionedOpsCatalog() public {
        // CCV config on the AdvancedPoolHooks: one representative lane with dummy verifier addresses.
        address[] memory outboundCCVs = new address[](1);
        outboundCCVs[0] = address(0xCC50);
        address[] memory inboundCCVs = new address[](1);
        inboundCCVs[0] = address(0xCC51);
        AdvancedPoolHooks.CCVConfigArg[] memory ccvArgs = new AdvancedPoolHooks.CCVConfigArg[](1);
        ccvArgs[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: EVM_SELECTOR,
            outboundCCVs: outboundCCVs,
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: inboundCCVs,
            thresholdInboundCCVs: new address[](0)
        });
        _assertBatchRoundTrip("apply-ccv-config", CctActions.applyCCVConfigUpdates(pool, ccvArgs));
        _assertBatchRoundTrip("set-ccv-threshold", CctActions.setThresholdAmount(pool, 500e18));

        // v1.x LockRelease rebalancer / liquidity surface.
        _assertBatchRoundTrip("set-rebalancer", CctActions.setRebalancer(pool, deployer));
        _assertBatchRoundTrip("provide-liquidity", CctActions.provideLiquidity(pool, 1e18));
        _assertBatchRoundTrip("withdraw-liquidity", CctActions.withdrawLiquidity(pool, 1e18));

        // 1.5.0-shaped lane update (single-argument ChainUpdate[] with an `allowed` flag, one remote pool).
        ITokenPoolV150.ChainUpdate[] memory v150Updates = new ITokenPoolV150.ChainUpdate[](1);
        v150Updates[0] = ITokenPoolV150.ChainUpdate({
            remoteChainSelector: EVM_SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(EVM_REMOTE_POOL),
            remoteTokenAddress: abi.encode(EVM_REMOTE_TOKEN),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        _assertBatchRoundTrip("apply-chain-updates-v150", CctActions.applyChainUpdatesV150(pool, v150Updates));

        // Whole-chain teardown shapes emitted by RemoveChain.s.sol, proven Safe-executable.
        // Modern (1.5.1+): the selector in `toRemove`, an empty `toAdd`.
        uint64[] memory chainRemovals = new uint64[](1);
        chainRemovals[0] = EVM_SELECTOR;
        TokenPool.ChainUpdate[] memory noAdds = new TokenPool.ChainUpdate[](0);
        _assertBatchRoundTrip("remove-chain-modern", CctActions.applyChainUpdates(pool, chainRemovals, noAdds));

        // 1.5.0: a single-argument `allowed:false` entry with disabled, zeroed rate configs.
        ITokenPoolV150.ChainUpdate[] memory v150Removal = new ITokenPoolV150.ChainUpdate[](1);
        v150Removal[0] = ITokenPoolV150.ChainUpdate({
            remoteChainSelector: EVM_SELECTOR,
            allowed: false,
            remotePoolAddress: "",
            remoteTokenAddress: "",
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        _assertBatchRoundTrip("remove-chain-v150", CctActions.applyChainUpdatesV150(pool, v150Removal));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mode B end-to-end: end-state equality with the EOA path
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The SAME `applyChainUpdates` inputs, executed (a) by the EOA owner and (b) by the Safe via
    ///      the full Mode B ceremony (ownership handed to the Safe first, itself via Mode B), must land
    ///      the IDENTICAL lane config on-chain.
    function test_ModeB_EndStateEqualsEoaPath() public {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        CctActions.Call[] memory laneCalls = CctActions.applyChainUpdates(pool, removes, updates);

        // (a) EOA path (pool still owned by the deployer).
        uint256 snapshot = vm.snapshotState();
        _exec(deployer, laneCalls);
        bytes memory eoaRemoteToken = TokenPool(pool).getRemoteToken(EVM_SELECTOR);
        bytes[] memory eoaRemotePools = TokenPool(pool).getRemotePools(EVM_SELECTOR);
        vm.revertToState(snapshot);

        // (b) Safe path: two-step ownership handoff (accept runs through Mode B — a single-call Safe
        // transaction), then the lane config through Mode B (also a single call).
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(address(safe));
        _runSafeDirect("modeb-accept-ownership", CctActions.acceptOwnership(pool));
        assertEq(TokenPool(pool).owner(), address(safe), "Safe must own the pool after the Mode B accept");

        _runSafeDirect("modeb-apply-chain-updates", laneCalls);

        assertTrue(TokenPool(pool).isSupportedChain(EVM_SELECTOR), "lane must be configured by the Safe");
        assertEq(TokenPool(pool).getRemoteToken(EVM_SELECTOR), eoaRemoteToken, "remote token must equal the EOA path");
        bytes[] memory safeRemotePools = TokenPool(pool).getRemotePools(EVM_SELECTOR);
        assertEq(safeRemotePools.length, eoaRemotePools.length, "remote pool count must equal the EOA path");
        for (uint256 i = 0; i < safeRemotePools.length; i++) {
            assertEq(safeRemotePools[i], eoaRemotePools[i], "remote pool must equal the EOA path");
        }
    }

    /// @dev The registration pair (claim + accept) executes atomically as ONE Safe MultiSend batch: the
    ///      claim sets the Safe (the token's CCIP admin) as pending administrator, so the accept in the
    ///      SAME batch succeeds.
    function test_ModeB_RegistrationPair_AtomicBatch() public {
        vm.prank(deployer);
        CrossChainToken(token).setCCIPAdmin(address(safe));

        CctActions.Call[] memory pair =
            CctActions.registerAndAcceptAdminViaGetCCIPAdmin(address(registryModule), address(registry), token);
        assertEq(pair.length, 2, "registration pair must be two calls");
        _runSafeDirect("modeb-registration-pair", pair);

        assertEq(registry.getTokenConfig(token).administrator, address(safe), "Safe must be the administrator");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(0), "pending must be cleared");
    }

    /// @dev The AccessControl registration pair executes atomically as ONE Safe MultiSend batch for a pure
    ///      OZ AccessControl token. With the Safe holding DEFAULT_ADMIN_ROLE, the claim registers the Safe
    ///      as pending administrator, so the accept in the SAME batch succeeds. This is the same governance
    ///      handoff the getCCIPAdmin path proves above, over the third (AccessControl) claim path.
    function test_ModeB_RegistrationPair_AccessControl_AtomicBatch() public {
        AccessControlOnlyToken acToken = new AccessControlOnlyToken(address(safe));

        CctActions.Call[] memory pair = CctActions.registerAndAcceptAdminViaAccessControl(
            address(registryModule), address(registry), address(acToken)
        );
        assertEq(pair.length, 2, "AccessControl registration pair must be two calls");
        _runSafeDirect("modeb-registration-pair-access-control", pair);

        assertEq(
            registry.getTokenConfig(address(acToken)).administrator, address(safe), "Safe must be the administrator"
        );
        assertEq(registry.getTokenConfig(address(acToken)).pendingAdministrator, address(0), "pending must be cleared");
    }

    /// @dev PR #9 liquidity-under-Safe: `ProvideLiquidity.s.sol` emits `approve` + `provideLiquidity` as ONE
    ///      two-call batch, and `provideLiquidity` requires `msg.sender == rebalancer`. With the Safe as the
    ///      pool's rebalancer, that batch must (a) round-trip through the Safe Transaction Builder / MultiSend
    ///      byte-identically in the correct order (token approve, then pool provideLiquidity), and (b) execute
    ///      atomically as ONE Safe transaction — the approve and the transferFrom it authorizes both run with
    ///      `msg.sender == Safe` inside the single MultiSend delegatecall, so the liquidity lands atomically.
    function test_ModeB_ProvideLiquidity_TwoCallBatch_UnderSafe() public {
        uint256 amount = 1_000e18;
        MockLockReleaseV1Pool lrPool = new MockLockReleaseV1Pool(IERC20(token));
        lrPool.setRebalancer(address(safe));
        deal(token, address(safe), amount);

        // The exact batch ProvideLiquidity.s.sol builds: approve(pool, amount) then provideLiquidity(amount).
        CctActions.Call[] memory batch = CctActions.concat(
            CctActions.approve(token, address(lrPool), amount), CctActions.provideLiquidity(address(lrPool), amount)
        );

        // Structure: two calls, in order, targeting the token (approve) then the pool (provideLiquidity).
        assertEq(batch.length, 2, "liquidity batch must be two calls");
        assertEq(batch[0].target, token, "call 0 must target the token (approve)");
        assertEq(
            batch[0].data, abi.encodeCall(IERC20.approve, (address(lrPool), amount)), "call 0 calldata must be approve"
        );
        assertEq(batch[1].target, address(lrPool), "call 1 must target the pool (provideLiquidity)");
        assertEq(
            batch[1].data,
            abi.encodeCall(ILockReleaseV1Liquidity.provideLiquidity, (amount)),
            "call 1 calldata must be provideLiquidity"
        );

        // (a) Byte-equal round-trip through the Transaction Builder JSON + the Mode B MultiSend payload.
        _assertBatchRoundTrip("provide-liquidity-under-safe", batch);

        // (b) Atomic execution as ONE Safe transaction: the Safe's tokens move into the pool.
        uint256 nonceBefore = safe.nonce();
        _runSafeDirect("modeb-provide-liquidity", batch);
        assertEq(safe.nonce(), nonceBefore + 1, "the two-call liquidity batch must consume exactly ONE Safe nonce");
        assertEq(IERC20(token).balanceOf(address(lrPool)), amount, "pool must hold the provided liquidity");
        assertEq(IERC20(token).balanceOf(address(safe)), 0, "Safe's tokens must have moved into the pool");
    }

    /// @dev Signature packing order is load-bearing: the SAME two valid signatures submitted in
    ///      DESCENDING signer order must be rejected by the Safe (GS026), while the ascending pack the
    ///      executor builds succeeds (proven by every other Mode B test).
    function test_ModeB_UnsortedSignatures_Revert() public {
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(address(safe));
        CctActions.Call[] memory calls = CctActions.acceptOwnership(pool);
        (address to, uint256 value, bytes memory data, uint8 operation) = SafeMode.encodeForSafe(calls);
        bytes32 txHash =
            safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());

        // Sign with both owners, then pack DESCENDING by signer address.
        (uint256 lowKey, uint256 highKey) =
            vm.addr(OWNER1_KEY) < vm.addr(OWNER2_KEY) ? (OWNER1_KEY, OWNER2_KEY) : (OWNER2_KEY, OWNER1_KEY);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(highKey, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(lowKey, txHash);
        bytes memory descending = abi.encodePacked(r1, s1, v1, r2, s2, v2);

        vm.expectRevert(bytes("GS026"));
        safe.execTransaction(to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), descending);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs `calls` through the full Safe ceremony (batch emission for review, then the Mode B
    ///      direct `execTransaction`) — the same code `MODE=safe SAFE_EXEC=direct` drives from the CLI,
    ///      with the batch name and Safe passed as parameters instead of process-wide env vars (forge
    ///      runs tests in parallel, so per-test `vm.setEnv` values would race across tests).
    function _runSafeDirect(string memory batchName, CctActions.Call[] memory calls) internal {
        SafeMode.emitBatch(batchName, address(safe), calls);
        SafeMode.execDirect(safe, calls);
    }

    /// @dev Emits the Transaction Builder JSON for `calls`, parses it back, and asserts every
    ///      transaction's `to`/`value`/`data` byte-equal the action-layer calls; then round-trips the
    ///      Mode B payload (`encodeForSafe`) back to the same calls.
    function _assertBatchRoundTrip(string memory name, CctActions.Call[] memory calls) internal {
        // JSON leg (the Transaction Builder / Mode A artifact).
        string memory path = SafeMode.emitBatch(name, address(safe), calls);
        string memory json = vm.readFile(path);
        for (uint256 i = 0; i < calls.length; i++) {
            string memory prefix = string.concat(".transactions[", vm.toString(i), "]");
            assertEq(
                vm.parseJsonAddress(json, string.concat(prefix, ".to")),
                calls[i].target,
                string.concat(name, ": batch 'to' mismatch")
            );
            assertEq(
                vm.parseJsonString(json, string.concat(prefix, ".value")),
                vm.toString(calls[i].value),
                string.concat(name, ": batch 'value' mismatch")
            );
            assertEq(
                vm.parseJsonBytes(json, string.concat(prefix, ".data")),
                calls[i].data,
                string.concat(name, ": batch 'data' mismatch")
            );
        }
        assertFalse(
            vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(calls.length), "]")),
            string.concat(name, ": batch must not carry extra transactions")
        );

        // Mode B leg (the execTransaction payload).
        (address to, uint256 value, bytes memory data, uint8 operation) = SafeMode.encodeForSafe(calls);
        if (calls.length == 1) {
            assertEq(operation, 0, string.concat(name, ": single call must be a CALL"));
            assertEq(to, calls[0].target, string.concat(name, ": Mode B 'to' mismatch"));
            assertEq(value, calls[0].value, string.concat(name, ": Mode B 'value' mismatch"));
            assertEq(data, calls[0].data, string.concat(name, ": Mode B 'data' mismatch"));
        } else {
            assertEq(operation, 1, string.concat(name, ": multi-call must DELEGATECALL MultiSend"));
            assertEq(
                to, SafeCanonical.MULTI_SEND_CALL_ONLY, string.concat(name, ": Mode B must target MultiSendCallOnly")
            );
            assertEq(value, 0, string.concat(name, ": MultiSend value must be zero"));
            CctActions.Call[] memory decoded = _decodeMultiSend(data);
            assertEq(decoded.length, calls.length, string.concat(name, ": MultiSend call count mismatch"));
            for (uint256 i = 0; i < calls.length; i++) {
                assertEq(decoded[i].target, calls[i].target, string.concat(name, ": MultiSend 'to' mismatch"));
                assertEq(decoded[i].value, calls[i].value, string.concat(name, ": MultiSend 'value' mismatch"));
                assertEq(decoded[i].data, calls[i].data, string.concat(name, ": MultiSend 'data' mismatch"));
            }
        }
    }

    /// @dev Decodes a `multiSend(bytes)` payload back into the individual calls: strips the selector,
    ///      abi-decodes the packed bytes, then walks the packed encoding (op:1 || to:20 || value:32 ||
    ///      dataLength:32 || data). Every inner operation must be a CALL (MultiSendCallOnly semantics).
    function _decodeMultiSend(bytes memory data) internal pure returns (CctActions.Call[] memory calls) {
        // Strip the 4-byte multiSend selector, then abi.decode the single `bytes` argument.
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = data[i + 4];
        }
        bytes memory packed = abi.decode(args, (bytes));

        // First pass: count the packed transactions.
        uint256 count;
        uint256 offset;
        while (offset < packed.length) {
            require(uint8(packed[offset]) == 0, "MultiSendCallOnly batch must contain only CALLs");
            uint256 dataLength = _readUint(packed, offset + 53);
            offset += 85 + dataLength;
            count++;
        }
        require(offset == packed.length, "malformed MultiSend packing");

        // Second pass: extract each call.
        calls = new CctActions.Call[](count);
        offset = 0;
        for (uint256 i = 0; i < count; i++) {
            address target = address(uint160(_readUint(packed, offset + 1) >> 96));
            uint256 value = _readUint(packed, offset + 21);
            uint256 dataLength = _readUint(packed, offset + 53);
            bytes memory callData = new bytes(dataLength);
            for (uint256 j = 0; j < dataLength; j++) {
                callData[j] = packed[offset + 85 + j];
            }
            calls[i] = CctActions.Call({target: target, value: value, data: callData});
            offset += 85 + dataLength;
        }
    }

    /// @dev Reads the 32-byte word at byte offset `start` of `b`.
    function _readUint(bytes memory b, uint256 start) private pure returns (uint256 v) {
        require(start + 32 <= b.length, "read past end of packed bytes");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            v := mload(add(add(b, 32), start))
        }
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
