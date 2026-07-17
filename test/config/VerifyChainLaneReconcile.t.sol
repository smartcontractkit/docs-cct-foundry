// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @dev Shared scratch-config plumbing for the lanes-rung tests: the scratch chain
/// CONFIG (pure API/chain facts, NO `lanes`/`roles`/`ccipBnM`) lives under `config/chains/zz-scratch-*`
/// and the declared `lanes{}` live in the gitignored `project/zz-scratch-*.json`. Every test writes its
/// own uniquely-named scratch chain (suites run in parallel and share the filesystem) and cleans both
/// files in setUp() (revert-safe), so a leftover from an aborted run can never poison a rerun. Scratch
/// lanes only ever point at scratch remote names, so a leftover cannot fail the doctor of a real chain.
abstract contract LaneReconcileScratch is Test {
    function _path(string memory name) internal pure returns (string memory) {
        return string.concat("config/chains/", name, ".json");
    }

    function _projPath(string memory name) internal view returns (string memory) {
        return ProjectStore.path(name);
    }

    /// @dev Writes a scratch chain config in the committed shape (all API/chain-fact schema keys —
    /// NO `lanes`/`roles`/`ccipBnM`, which live in `project/`), keyed by a fake-but-valid
    /// chainId/selector no other test uses.
    function _writeScratchChain(string memory name, uint256 chainId, uint64 selector) internal {
        string memory obj = string.concat("scratch-", name);
        vm.serializeString(obj, "name", name);
        vm.serializeString(obj, "displayName", string.concat("Scratch ", name));
        vm.serializeString(obj, "chainNameIdentifier", "ZZ_SCRATCH_LANECHK");
        vm.serializeString(obj, "chainFamily", "evm");
        vm.serializeString(obj, "environment", "testnet");
        vm.serializeString(obj, "chainId", vm.toString(chainId));
        vm.serializeString(obj, "chainSelector", vm.toString(selector));
        vm.serializeString(obj, "rpcEnv", "ZZ_SCRATCH_LANECHK_RPC_URL");
        vm.serializeString(obj, "explorerUrl", "https://example.invalid");
        vm.serializeString(obj, "nativeCurrencySymbol", "ZZZ");
        string memory ccipObj = string.concat("scratch-ccip-", name);
        vm.serializeAddress(ccipObj, "router", address(2));
        vm.serializeAddress(ccipObj, "rmnProxy", address(3));
        vm.serializeAddress(ccipObj, "tokenAdminRegistry", address(5));
        vm.serializeAddress(ccipObj, "registryModuleOwnerCustom", address(4));
        vm.serializeAddress(ccipObj, "link", address(1));
        vm.serializeAddress(ccipObj, "feeQuoter", address(6));
        vm.serializeAddress(ccipObj, "tokenPoolFactory", address(7));
        string memory ccipJson = vm.serializeAddress(ccipObj, "feeTokens", new address[](0));
        vm.writeFile(_path(name), vm.serializeString(obj, "ccip", ccipJson));
    }

    /// @dev Deletes leftover scratch files (config + project) from a prior aborted run. Called from
    /// setUp() so cleanup happens before every test, not at the end of a happy path a failing assertion
    /// would skip - the next run always starts (and leaves the tree) clean.
    function _cleanupScratch(string[] memory names) internal {
        for (uint256 i = 0; i < names.length; i++) {
            _cleanupScratchOne(names[i]);
        }
    }

    /// @dev Single-name variant for end-of-test cleanup: a test removes ONLY the fixtures it owns.
    /// Suite siblings run in parallel, so a suite-wide sweep at end-of-test would delete a running
    /// sibling's files; the setUp() sweep stays the revert-safe guarantee.
    function _cleanupScratchOne(string memory name) internal {
        string memory p = _path(name);
        if (vm.exists(p)) vm.removeFile(p);
        string memory proj = _projPath(name);
        if (vm.exists(proj)) vm.removeFile(proj);
    }

    /// @dev Declares the scratch chain's `lanes{}` in its PROJECT store (`project/<name>.json`) with ONE
    /// entry (`remoteName` -> the raw entry JSON), composed as a raw string so tests control optional
    /// blocks (`inbound{}`, `v2{}`) exactly. Seeds the project skeleton first so the targeted `.lanes`
    /// write never raw-reverts. This is where the lane SOURCE (`LanePolicySource`) and the doctor read.
    function _declareLane(string memory name, string memory remoteName, string memory laneEntryJson) internal {
        ProjectStore.seedIfAbsent(name);
        vm.writeJson(string.concat("{\"", remoteName, "\":", laneEntryJson, "}"), _projPath(name), ".lanes");
    }

    /// @dev A core lane entry (`remoteSelector`/`capacity`/`rate`) with `extraJson` appended verbatim
    /// (e.g. `,"inbound":{...}` or `,"v2":{...}`; empty for a core-only entry).
    function _laneEntry(uint64 selector, uint256 capacity, uint256 rate, string memory extraJson)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "{\"remoteSelector\":\"",
            vm.toString(selector),
            "\",\"capacity\":\"",
            vm.toString(capacity),
            "\",\"rate\":\"",
            vm.toString(rate),
            "\"",
            extraJson,
            "}"
        );
    }

    /// @dev Declares the scratch chain's `poolPolicy{}` block (pool-scoped policy: `ccvThreshold`,
    /// `finality{}`) by authoring the WHOLE schema-3 project file in canonical sorted-key order —
    /// the hand-edit simulation. Production has no `poolPolicy` writer (the block's one writer is a
    /// reviewed hand edit) and the targeted 3-arg `vm.writeJson` cannot create a missing key, so
    /// tests write the full document. Compose with `_declareLane` AFTER this call when a test needs
    /// both (the targeted `.lanes` write preserves the sibling `poolPolicy`).
    function _declarePoolPolicy(string memory name, string memory poolPolicyJson) internal {
        vm.writeFile(
            _projPath(name),
            string.concat(
                "{\"addresses\":{\"active\":{},\"deployments\":{}},\"lanes\":{},\"poolPolicy\":",
                poolPolicyJson,
                ",\"roles\":{},\"schema\":3}"
            )
        );
    }
}

/// @notice The `make doctor` lanes rung reconciles the declared `lanes{}` policy against the ON-CHAIN
/// pool, both directions: declared-vs-live drift is a FAIL naming the field, while forward-intent
/// states (declared-but-not-applied), undeclared on-chain lanes, and unanswered reads stay WARN.
/// These fork tests drive `VerifyChain.checkLanesOnChainForTest` against the repo's own 2.0.0
/// fixture pool (full control of the applied state) and against the live externally deployed 1.6.1
/// fixture pool (tests/pool-migration-v1to2/fixtures.json), asserting the (fails, warns) contract
/// per state.
contract VerifyChainLaneReconcileForkTest is BaseForkTest, LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_870_000_000_000_000_001;
    uint128 internal constant CAPACITY = 1000e18;
    uint128 internal constant RATE = 100e18;

    // Live externally deployed Sepolia fixture: BurnMintTokenPool 1.6.1 with a Mantle Sepolia lane applied.
    address internal constant LIVE_161_POOL = 0x898ABAA106686F91f783166Abe336E7C7423Ca89;
    uint64 internal constant MANTLE_SELECTOR = 8_236_463_271_206_331_221;

    address internal pool;
    address internal deployer;

    function setUp() public override {
        super.setUp();
        _clean();
        (, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](10);
        names[0] = "zz-scratch-lanechk-a1";
        names[1] = "zz-scratch-lanechk-a2";
        names[2] = "zz-scratch-lanechk-a3";
        names[3] = "zz-scratch-lanechk-a4";
        names[4] = "zz-scratch-lanechk-a5";
        names[5] = "zz-scratch-lanechk-a6";
        names[6] = "zz-scratch-lanechk-a7";
        names[7] = "zz-scratch-lanechk-a8";
        names[8] = "zz-scratch-lanechk-a9";
        names[9] = "zz-scratch-lanechk-a10";
        _cleanupScratch(names);
    }

    /// @dev Applies the scratch lane on the fixture pool with the given standard buckets.
    function _applyLane(RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) internal {
        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(address(0xD001));
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: REMOTE_SELECTOR,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(address(0xD002)),
            outboundRateLimiterConfig: outbound,
            inboundRateLimiterConfig: inbound
        });
        vm.prank(deployer);
        TokenPool(pool).applyChainUpdates(new uint64[](0), adds);
    }

    function _enabled(uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate});
    }

    function _disabled() internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
    }

    function _run(string memory name) internal returns (uint256 fails, uint256 warns) {
        return new VerifyChain().checkLanesOnChainForTest(name, pool);
    }

    // PASS: declared lane applied on-chain with matching outbound policy. The pool also carries an
    // enabled INBOUND bucket and an on-chain fee config that the entry does NOT declare - undeclared
    // blocks are not reconciled, so neither may WARN.
    function test_Lanes_Pass_DeclaredAndApplied() public {
        string memory name = "zz-scratch-lanechk-a1";
        _writeScratchChain(name, 887000101, 8_870_001_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-r1", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, ""));
        _applyLane(_enabled(CAPACITY, RATE), _enabled(CAPACITY * 2, RATE * 2));
        _applyFeeConfig(90_000, 32, 0, 0, 10, 25);

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 0, "match must never FAIL");
        assertEq(warns, 0, "match must not WARN (undeclared inbound/v2 blocks are not reconciled)");

        _cleanupScratchOne(name);
    }

    // WARN: declared but not applied on-chain.
    function test_Lanes_Warn_DeclaredNotApplied() public {
        string memory name = "zz-scratch-lanechk-a2";
        _writeScratchChain(name, 887000201, 8_870_002_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-r2", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, ""));

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 0, "an unapplied lane must never FAIL");
        assertEq(warns, 1, "an unapplied lane must emit exactly one WARN");

        _cleanupScratchOne(name);
    }

    // FAIL: applied, but the live outbound bucket drifted from the declared policy (a deliberate
    // out-of-band throttle is recorded by updating the declaration; until then the doctor is red).
    function test_Lanes_Fail_OutboundRateLimitDrift() public {
        string memory name = "zz-scratch-lanechk-a3";
        _writeScratchChain(name, 887000301, 8_870_003_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-r3", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, ""));
        _applyLane(_enabled(CAPACITY / 2, RATE / 2), _disabled()); // emergency-throttle shape

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 1, "rate-limit drift must FAIL naming the bucket");
        assertEq(warns, 0, "rate-limit drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    // WARN: the pool supports a selector on-chain that lanes{} does not declare.
    function test_Lanes_Warn_OnChainLaneNotDeclared() public {
        string memory name = "zz-scratch-lanechk-a4";
        _writeScratchChain(name, 887000401, 8_870_004_010_000_000_001);
        _applyLane(_enabled(CAPACITY, RATE), _disabled()); // applied, but lanes{} stays empty

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 0, "an undeclared on-chain lane must never FAIL");
        assertEq(warns, 1, "an undeclared on-chain lane must emit exactly one WARN");

        _cleanupScratchOne(name);
    }

    // SKIP: no pool recorded in the registry - nothing to reconcile, no WARN, no FAIL.
    function test_Lanes_Skip_WhenNoPoolRecorded() public {
        string memory name = "zz-scratch-lanechk-a5";
        _writeScratchChain(name, 887000501, 8_870_005_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-r5", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, ""));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(0));
        assertEq(fails, 0, "no-pool must never FAIL");
        assertEq(warns, 0, "no-pool is a SKIP, not a WARN");

        _cleanupScratchOne(name);
    }

    // Declared inbound block: reconciled when matching, one FAIL when drifting.
    function test_Lanes_Inbound_MatchThenDrift() public {
        string memory name = "zz-scratch-lanechk-a6";
        _writeScratchChain(name, 887000601, 8_870_006_010_000_000_001);
        string memory inboundBlock = string.concat(
            ",\"inbound\":{\"capacity\":\"", vm.toString(CAPACITY), "\",\"rate\":\"", vm.toString(RATE), "\"}"
        );
        _declareLane(name, "zz-scratch-lanechk-r6", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, inboundBlock));
        _applyLane(_enabled(CAPACITY, RATE), _enabled(CAPACITY, RATE));

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 0, "matching inbound must never FAIL");
        assertEq(warns, 0, "matching inbound must not WARN");

        // Drift the live inbound bucket out from under the declared block.
        TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
        args[0] = TokenPool.RateLimitConfigArgs({
            remoteChainSelector: REMOTE_SELECTOR,
            fastFinality: false,
            outboundRateLimiterConfig: _enabled(CAPACITY, RATE),
            inboundRateLimiterConfig: _enabled(CAPACITY / 2, RATE / 2)
        });
        vm.prank(deployer);
        TokenPool(pool).setRateLimitConfig(args);

        (fails, warns) = _run(name);
        assertEq(fails, 1, "inbound drift must FAIL naming the bucket");
        assertEq(warns, 0, "inbound drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    // Declared v2.fastFinality buckets on the 2.0.0 pool: reconciled when matching, FAIL on drift.
    function test_Lanes_V2FastFinality_MatchThenDrift() public {
        string memory name = "zz-scratch-lanechk-a7";
        _writeScratchChain(name, 887000701, 8_870_007_010_000_000_001);
        string memory v2Block = string.concat(
            ",\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"",
            vm.toString(CAPACITY / 2),
            "\",\"rate\":\"",
            vm.toString(RATE / 2),
            "\"},\"inbound\":{\"capacity\":\"",
            vm.toString(CAPACITY / 2),
            "\",\"rate\":\"",
            vm.toString(RATE / 2),
            "\"}}}"
        );
        _declareLane(name, "zz-scratch-lanechk-r7", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, v2Block));
        _applyLane(_enabled(CAPACITY, RATE), _disabled());
        _setFastFinality(_enabled(CAPACITY / 2, RATE / 2), _enabled(CAPACITY / 2, RATE / 2));

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 0, "matching fast-finality buckets must never FAIL");
        assertEq(warns, 0, "matching fast-finality buckets must not WARN");

        _setFastFinality(_enabled(CAPACITY / 4, RATE / 4), _enabled(CAPACITY / 2, RATE / 2));
        (fails, warns) = _run(name);
        assertEq(fails, 1, "fast-finality outbound drift must FAIL naming the bucket");
        assertEq(warns, 0, "fast-finality drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    // Declared v2.feeConfig on the 2.0.0 pool: reconciled per field; a declared block with no
    // enabled on-chain config is the same declared-vs-live contradiction as a drifted field (FAIL).
    function test_Lanes_V2FeeConfig_MatchDriftAndDisabled() public {
        string memory name = "zz-scratch-lanechk-a8";
        _writeScratchChain(name, 887000801, 8_870_008_010_000_000_001);
        string memory feeBlock =
            ",\"v2\":{\"feeConfig\":{\"destGasOverhead\":\"90000\",\"destBytesOverhead\":\"32\",\"finalityTransferFeeBps\":\"10\",\"fastFinalityTransferFeeBps\":\"25\"}}";
        _declareLane(name, "zz-scratch-lanechk-r8", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, feeBlock));
        _applyLane(_enabled(CAPACITY, RATE), _disabled());

        // Declared but no enabled on-chain fee config -> one FAIL.
        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 1, "a declared fee config with no enabled on-chain config must FAIL");
        assertEq(warns, 0, "the missing fee config must not additionally WARN");

        // Applied matching -> clean.
        _applyFeeConfig(90_000, 32, 0, 0, 10, 25);
        (fails, warns) = _run(name);
        assertEq(fails, 0, "matching fee config must never FAIL");
        assertEq(warns, 0, "matching fee config must not WARN");

        // One live field drifts -> exactly one FAIL (per-field reconciliation).
        _applyFeeConfig(90_000, 32, 0, 0, 40, 25);
        (fails, warns) = _run(name);
        assertEq(fails, 1, "one drifted fee-config field must FAIL naming the field");
        assertEq(warns, 0, "fee-config drift must not additionally WARN");

        _cleanupScratchOne(name);
    }

    // Live externally deployed 1.6.1 pool (v1 getter surface): with NOTHING declared, the rung must
    // walk the pool's real on-chain lanes through the version-dispatched read path without ever
    // FAILing or hard-reverting - undeclared on-chain lanes are WARNs, and external state this repo
    // does not pin must never turn the doctor red. (A declared policy against external state would
    // legitimately FAIL on drift, so this test deliberately declares none.)
    function test_Lanes_Live161Pool_NeverFailsOrReverts() public {
        assertGt(LIVE_161_POOL.code.length, 0, "live 1.6.1 fixture pool missing on Sepolia fork");
        string memory name = "zz-scratch-lanechk-a9";
        _writeScratchChain(name, 887000901, 8_870_009_010_000_000_001);

        (uint256 fails,) = new VerifyChain().checkLanesOnChainForTest(name, LIVE_161_POOL);
        assertEq(fails, 0, "the lanes rung must never FAIL on a live externally deployed pool with nothing declared");

        _cleanupScratchOne(name);
    }

    // The aggregate-then-verdict contract: THREE simultaneous drifts (standard outbound bucket,
    // fast-finality outbound bucket, one fee-config field) are all named in ONE run - the rung
    // never stops at the first finding - and remediating all three in a batch returns the rung to
    // totally clean.
    function test_Lanes_MultiDrift_AllNamedInOneRun_ThenRemediated() public {
        string memory name = "zz-scratch-lanechk-a10";
        _writeScratchChain(name, 887001001, 8_870_010_010_000_000_002);
        string memory extra = string.concat(
            ",\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"",
            vm.toString(CAPACITY / 2),
            "\",\"rate\":\"",
            vm.toString(RATE / 2),
            "\"}},\"feeConfig\":{\"destGasOverhead\":\"90000\",\"finalityTransferFeeBps\":\"10\"}}"
        );
        _declareLane(name, "zz-scratch-lanechk-r10", _laneEntry(REMOTE_SELECTOR, CAPACITY, RATE, extra));

        // All three surfaces drifted from the declaration at once.
        _applyLane(_enabled(CAPACITY / 2, RATE / 2), _disabled());
        _setFastFinality(_enabled(CAPACITY / 4, RATE / 4), _disabled());
        _applyFeeConfig(90_000, 32, 0, 0, 40, 25);

        (uint256 fails, uint256 warns) = _run(name);
        assertEq(fails, 3, "every drifted field must be named in one run (outbound + fast-finality + fee field)");
        assertEq(warns, 0, "drift must not additionally WARN");

        // Batch remediation -> clean (the lane is already applied, so the standard bucket is
        // re-set through the rate-limit setter, not a second applyChainUpdates).
        _setStandard(_enabled(CAPACITY, RATE), _disabled());
        _setFastFinality(_enabled(CAPACITY / 2, RATE / 2), _disabled());
        _applyFeeConfig(90_000, 32, 0, 0, 10, 25);
        (fails, warns) = _run(name);
        assertEq(fails, 0, "remediated lane must be clean");
        assertEq(warns, 0, "remediated lane must not WARN");

        _cleanupScratchOne(name);
    }

    function _setFastFinality(RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) internal {
        _setBuckets(true, outbound, inbound);
    }

    function _setStandard(RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) internal {
        _setBuckets(false, outbound, inbound);
    }

    function _setBuckets(bool fastFinality, RateLimiter.Config memory outbound, RateLimiter.Config memory inbound)
        internal
    {
        TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
        args[0] = TokenPool.RateLimitConfigArgs({
            remoteChainSelector: REMOTE_SELECTOR,
            fastFinality: fastFinality,
            outboundRateLimiterConfig: outbound,
            inboundRateLimiterConfig: inbound
        });
        vm.prank(deployer);
        TokenPool(pool).setRateLimitConfig(args);
    }

    function _applyFeeConfig(
        uint32 destGasOverhead,
        uint32 destBytesOverhead,
        uint32 finalityFeeUSDCents,
        uint32 fastFinalityFeeUSDCents,
        uint16 finalityTransferFeeBps,
        uint16 fastFinalityTransferFeeBps
    ) internal {
        TokenPool.TokenTransferFeeConfigArgs[] memory args = new TokenPool.TokenTransferFeeConfigArgs[](1);
        args[0] = TokenPool.TokenTransferFeeConfigArgs({
            destChainSelector: REMOTE_SELECTOR,
            tokenTransferFeeConfig: IPoolV2.TokenTransferFeeConfig({
                destGasOverhead: destGasOverhead,
                destBytesOverhead: destBytesOverhead,
                finalityFeeUSDCents: finalityFeeUSDCents,
                fastFinalityFeeUSDCents: fastFinalityFeeUSDCents,
                finalityTransferFeeBps: finalityTransferFeeBps,
                fastFinalityTransferFeeBps: fastFinalityTransferFeeBps,
                isEnabled: true
            })
        });
        vm.prank(deployer);
        TokenPool(pool).applyTokenTransferFeeConfigUpdates(args, new uint64[](0));
    }
}

/// @dev A minimal v1-surface pool mock: `typeAndVersion()` is constructor-set, the chain-membership
/// getters answer for one selector once "applied", and ONLY the per-direction v1 rate-limit getters
/// exist (no `getCurrentRateLimiterState(uint64,bool)`), so any v2-first read on it reverts. That
/// absence is the point: a clean reconcile proves the rung dispatched the v1 getters.
contract MockV1Pool {
    string private s_typeAndVersion;
    uint64 private immutable i_selector;
    bool private s_applied;
    RateLimiter.TokenBucket private s_outbound;
    RateLimiter.TokenBucket private s_inbound;

    constructor(string memory typeAndVersion_, uint64 selector_) {
        s_typeAndVersion = typeAndVersion_;
        i_selector = selector_;
    }

    function applyLane(RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) external {
        s_applied = true;
        s_outbound = outbound;
        s_inbound = inbound;
    }

    function typeAndVersion() external view returns (string memory) {
        return s_typeAndVersion;
    }

    function isSupportedChain(uint64 remoteChainSelector) external view returns (bool) {
        return s_applied && remoteChainSelector == i_selector;
    }

    function getSupportedChains() external view returns (uint64[] memory chains) {
        if (!s_applied) return new uint64[](0);
        chains = new uint64[](1);
        chains[0] = i_selector;
    }

    function getCurrentOutboundRateLimiterState(uint64) external view returns (RateLimiter.TokenBucket memory) {
        return s_outbound;
    }

    function getCurrentInboundRateLimiterState(uint64) external view returns (RateLimiter.TokenBucket memory) {
        return s_inbound;
    }
}

/// @dev An UNCATALOGED typeAndVersion over a v2-shaped read surface: the chain-support getters plus
/// ONLY the v2 rate-limit getter `getCurrentRateLimiterState(uint64,bool)` - deliberately NO v1
/// per-direction getters, so a read that reaches this pool succeeds only through the UNKNOWN
/// branch's v2-first attempt (mirrors MockV2SurfaceFuturePool in test/actions/PoolVersionDispatch.t.sol).
contract MockV2OnlyFuturePool {
    uint64 private immutable i_selector;
    bool private s_applied;
    RateLimiter.TokenBucket private s_outbound;
    RateLimiter.TokenBucket private s_inbound;

    constructor(uint64 selector_) {
        i_selector = selector_;
    }

    function applyLane(RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) external {
        s_applied = true;
        s_outbound = outbound;
        s_inbound = inbound;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.1.0";
    }

    function isSupportedChain(uint64 remoteChainSelector) external view returns (bool) {
        return s_applied && remoteChainSelector == i_selector;
    }

    function getSupportedChains() external view returns (uint64[] memory chains) {
        if (!s_applied) return new uint64[](0);
        chains = new uint64[](1);
        chains[0] = i_selector;
    }

    function getCurrentRateLimiterState(uint64, bool)
        external
        view
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound)
    {
        return (s_outbound, s_inbound);
    }
}

/// @notice Offline (no fork) lanes-rung tests against v1-shaped pool mocks: the version-dispatched
/// read path for a 1.5.0 pool, the v2-block-on-a-cataloged-1.x-pool FAIL, and the reads-degrade
/// path for an unrecognized version. No RPC involved - the hook injects the mock as the pool.
contract VerifyChainLaneReconcileMockTest is LaneReconcileScratch {
    uint64 internal constant SEL = 8_870_010_000_000_000_001;
    uint128 internal constant CAPACITY = 1000e18;
    uint128 internal constant RATE = 100e18;

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[] memory names = new string[](6);
        names[0] = "zz-scratch-lanechk-m1";
        names[1] = "zz-scratch-lanechk-m2";
        names[2] = "zz-scratch-lanechk-m3";
        names[3] = "zz-scratch-lanechk-m4";
        names[4] = "zz-scratch-lanechk-m5";
        names[5] = "zz-scratch-lanechk-m6";
        _cleanupScratch(names);
    }

    function _bucket(bool isEnabled, uint128 capacity, uint128 rate)
        internal
        pure
        returns (RateLimiter.TokenBucket memory)
    {
        return
            RateLimiter.TokenBucket({tokens: 0, lastUpdated: 0, isEnabled: isEnabled, capacity: capacity, rate: rate});
    }

    function _inboundBlock() internal pure returns (string memory) {
        return string.concat(
            ",\"inbound\":{\"capacity\":\"", vm.toString(CAPACITY), "\",\"rate\":\"", vm.toString(RATE), "\"}"
        );
    }

    // A 1.5.0-shaped pool: outbound AND inbound declared and matching -> clean, which proves the
    // rung read through the v1 getters (the mock has no v2 getter to fall back from).
    function test_Lanes_V150Pool_VersionDispatchedReads() public {
        string memory name = "zz-scratch-lanechk-m1";
        _writeScratchChain(name, 887001101, 8_870_011_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-mr1", _laneEntry(SEL, CAPACITY, RATE, _inboundBlock()));

        MockV1Pool mockPool = new MockV1Pool("BurnMintTokenPool 1.5.0", SEL);
        mockPool.applyLane(_bucket(true, CAPACITY, RATE), _bucket(true, CAPACITY, RATE));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 0, "1.5.0 reconcile must never FAIL");
        assertEq(warns, 0, "matching 1.5.0 lane must not WARN (v1 getters dispatched)");

        _cleanupScratchOne(name);
    }

    // A declared v2{} block against a CATALOGED 1.5.0 pool is a version-gate FAIL by name, not a
    // read attempt (the v1 pool has no fast-finality/fee/ccv surface, and the declaration can never
    // converge on this pool - fix the declaration or migrate the pool).
    function test_Lanes_Fail_V2BlockOnCataloged1xPool() public {
        string memory name = "zz-scratch-lanechk-m2";
        _writeScratchChain(name, 887001201, 8_870_012_010_000_000_001);
        string memory v2Block =
            ",\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"1\",\"rate\":\"1\"}},\"feeConfig\":{\"destGasOverhead\":\"90000\"}}";
        _declareLane(name, "zz-scratch-lanechk-mr2", _laneEntry(SEL, CAPACITY, RATE, v2Block));

        MockV1Pool mockPool = new MockV1Pool("BurnMintTokenPool 1.5.0", SEL);
        mockPool.applyLane(_bucket(true, CAPACITY, RATE), _bucket(true, CAPACITY, RATE));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 1, "a v2 block on a cataloged 1.x pool must FAIL the version gate by name");
        assertEq(warns, 0, "the version-gate FAIL must not additionally WARN");

        _cleanupScratchOne(name);
    }

    // An unrecognized typeAndVersion: one best-effort WARN, then reads degrade (v2 getter first,
    // v1 fallback - the mock only answers v1) and still reconcile the declared policy.
    function test_Lanes_Warn_UnknownVersionDegradesToBestEffort() public {
        string memory name = "zz-scratch-lanechk-m3";
        _writeScratchChain(name, 887001301, 8_870_013_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-mr3", _laneEntry(SEL, CAPACITY, RATE, ""));

        MockV1Pool mockPool = new MockV1Pool("FancyForkPool 9.9.9", SEL);
        mockPool.applyLane(_bucket(true, CAPACITY, RATE), _bucket(true, CAPACITY, RATE));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 0, "an unrecognized pool version must never FAIL a read path");
        assertEq(warns, 1, "exactly one WARN (the unknown-version notice); the reads still reconcile");

        _cleanupScratchOne(name);
    }

    // The other half of the UNKNOWN reads-degrade ladder: an uncataloged typeAndVersion over a pool
    // that answers ONLY the v2 getter `getCurrentRateLimiterState(uint64,bool)` (no v1 getters).
    // The read must succeed through the v2-FIRST attempt - matching declared policy reconciles to
    // exactly the unknown-version WARN, and a live drift on the same pool is still a FAIL: only the
    // version GATES carve out UNKNOWN; a successfully read value that contradicts the declaration
    // is proven drift regardless of catalog status (a failed read would WARN "does not answer").
    function test_Lanes_UnknownVersion_ReadsThroughV2GetterFirst() public {
        string memory name = "zz-scratch-lanechk-m4";
        _writeScratchChain(name, 887001401, 8_870_014_010_000_000_001);
        _declareLane(name, "zz-scratch-lanechk-mr4", _laneEntry(SEL, CAPACITY, RATE, ""));

        MockV2OnlyFuturePool mockPool = new MockV2OnlyFuturePool(SEL);
        mockPool.applyLane(_bucket(true, CAPACITY, RATE), _bucket(true, CAPACITY, RATE));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 0, "an unrecognized pool version must never FAIL a read path");
        assertEq(warns, 1, "exactly one WARN (the unknown-version notice): the v2-first read succeeded and matched");

        // Same pool, drifted live bucket: the reconcile must see the mock's NEW values through the
        // v2 getter (unknown-version WARN + one drift FAIL).
        mockPool.applyLane(_bucket(true, CAPACITY + 1, RATE), _bucket(true, CAPACITY, RATE));
        (fails, warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 1, "successfully read drift FAILs even under an unrecognized version");
        assertEq(warns, 1, "the unknown-version notice stays a WARN: the v2 getter's values were read");

        _cleanupScratchOne(name);
    }

    // A declared v2{} block against an UNCATALOGED version: the gate degrades to a WARN (no
    // fast-finality/fee/ccv read attempted) next to the general unknown-version notice - never a
    // FAIL. The standard bucket still reconciles best-effort (matching here, so quiet).
    function test_Lanes_Warn_V2BlockOnUnknownVersion() public {
        string memory name = "zz-scratch-lanechk-m6";
        _writeScratchChain(name, 887001601, 8_870_016_010_000_000_001);
        string memory v2Block = ",\"v2\":{\"feeConfig\":{\"destGasOverhead\":\"90000\"}}";
        _declareLane(name, "zz-scratch-lanechk-mr6", _laneEntry(SEL, CAPACITY, RATE, v2Block));

        MockV1Pool mockPool = new MockV1Pool("FancyForkPool 9.9.9", SEL);
        mockPool.applyLane(_bucket(true, CAPACITY, RATE), _bucket(true, CAPACITY, RATE));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 0, "a v2 block on an uncataloged version must never FAIL");
        assertEq(warns, 2, "the unknown-version notice plus the v2 gate WARN");

        _cleanupScratchOne(name);
    }

    // The totally-quiet baseline: an EMPTY lanes{} declaration against a pool with ZERO on-chain
    // lanes has nothing to reconcile in either direction - the rung must return exactly
    // (0 fails, 0 warns).
    function test_Lanes_EmptyDeclaredAndEmptyOnChain_TotallyQuiet() public {
        string memory name = "zz-scratch-lanechk-m5";
        _writeScratchChain(name, 887001501, 8_870_015_010_000_000_001);
        // No _declareLane: the scratch chain ships the empty lanes{} object.

        MockV1Pool mockPool = new MockV1Pool("BurnMintTokenPool 1.5.0", SEL);
        // No applyLane: getSupportedChains() returns an empty array.

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(name, address(mockPool));
        assertEq(fails, 0, "empty lanes{} vs zero on-chain lanes must not FAIL");
        assertEq(warns, 0, "empty lanes{} vs zero on-chain lanes must not WARN (totally quiet baseline)");

        _cleanupScratchOne(name);
    }
}
