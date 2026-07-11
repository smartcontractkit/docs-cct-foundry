// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {CctActions, ITokenPoolV150} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {PoolVersion} from "../../script/utils/PoolVersion.s.sol";
import {ApplyChainUpdates} from "../../script/setup/ApplyChainUpdates.s.sol";
import {AddRemotePool} from "../../script/configure/remote-pools/AddRemotePool.s.sol";
import {RemoveRemotePool} from "../../script/configure/remote-pools/RemoveRemotePool.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract MockTypeAndVersion {
    string public typeAndVersion;

    constructor(string memory t) {
        typeAndVersion = t;
    }
}

contract NoTypeAndVersion {}

/// @dev typeAndVersion plus the v1 rate-limit getter surface (no v2 getter).
contract MockV1SurfaceDevPool {
    function typeAndVersion() external pure returns (string memory) {
        return "LockReleaseTokenPool 1.6.x-dev";
    }

    function getCurrentOutboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}

    function getCurrentInboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}
}

/// @dev typeAndVersion (an uncataloged future version) plus ONLY the v2 rate-limit getter.
contract MockV2SurfaceFuturePool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.1.0";
    }

    function getCurrentRateLimiterState(uint64, bool)
        external
        pure
        returns (RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i)
    {}
}

/// @dev A faithful 1.5.0 read surface: typeAndVersion, isSupportedChain, and the SINGULAR
///      getRemotePool. There is deliberately no getRemotePools (absent on 1.5.0), so any code that
///      reads the plural getter before fencing the version reverts raw instead of by name.
contract Mock150Pool {
    bytes internal s_remotePool;

    constructor(bytes memory remotePool) {
        s_remotePool = remotePool;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.5.0";
    }

    function isSupportedChain(uint64) external pure returns (bool) {
        return true;
    }

    function getRemotePool(uint64) external view returns (bytes memory) {
        return s_remotePool;
    }

    function getCurrentOutboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}

    function getCurrentInboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}
}

/// @dev A modern (1.5.1+) read surface: typeAndVersion plus the PLURAL getRemotePools only.
contract MockModernPool {
    bytes[] internal s_remotePools;

    constructor(bytes memory remotePool) {
        s_remotePools.push(remotePool);
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.6.1";
    }

    function getRemotePools(uint64) external view returns (bytes[] memory) {
        return s_remotePools;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shims and harnesses
// ─────────────────────────────────────────────────────────────────────────────

/// @dev External-call shim: revert-asserting tests call the library through this contract so
///      try/catch (and expectRevert, which arms the next external call) applies to the call.
contract ResolverShim {
    function resolve(address pool) external view returns (PoolVersions.Version, string memory) {
        return PoolVersion.resolve(pool);
    }

    function resolveWith(address pool, string memory overrideSpec)
        external
        view
        returns (PoolVersions.Version, string memory)
    {
        return PoolVersion.resolveWith(pool, overrideSpec);
    }

    function tryResolve(address pool) external view returns (bool, PoolVersions.Version, string memory) {
        return PoolVersion.tryResolve(pool);
    }

    function remotePools(address pool, PoolVersions.Version version, uint64 selector)
        external
        view
        returns (bytes[] memory)
    {
        return PoolVersion.remotePools(pool, version, selector);
    }

    function requireSupports(PoolVersions.Op op, PoolVersions.Version version, address pool) external pure {
        PoolVersions.requireSupports(op, version, pool);
    }

    function setRateLimits(
        address pool,
        PoolVersions.Version version,
        uint64 selector,
        bool fastFinality,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) external pure returns (CctActions.Call[] memory) {
        return CctActions.setRateLimits(pool, version, selector, fastFinality, outbound, inbound);
    }
}

/// @dev Exposes AddRemotePool's post-resolution body so the fence-before-read ordering is testable
///      with an injected pool address (the env-based pool resolution is process-global and cannot be
///      exercised race-free while suites run in parallel).
contract AddRemotePoolHarness is AddRemotePool {
    function invoke(
        address tokenPoolAddress,
        address remotePoolAddress,
        uint64 remoteChainSelector,
        string memory destChainName,
        uint256 destChainId
    ) external {
        helperConfig = new HelperConfig();
        _addRemotePool(tokenPoolAddress, remotePoolAddress, remoteChainSelector, destChainName, destChainId);
    }
}

/// @dev Exposes RemoveRemotePool's post-resolution body for the same fence-before-read proof.
contract RemoveRemotePoolHarness is RemoveRemotePool {
    function invoke(
        address tokenPoolAddress,
        address remotePoolAddress,
        uint64 remoteChainSelector,
        string memory destChainName,
        uint256 destChainId
    ) external {
        helperConfig = new HelperConfig();
        _removeRemotePool(tokenPoolAddress, remotePoolAddress, remoteChainSelector, destChainName, destChainId);
    }
}

/// @dev Exposes the script's internal conversion and the exhaustive lane-update dispatch switch.
contract ApplyChainUpdatesHarness is ApplyChainUpdates {
    function convert(TokenPool.ChainUpdate[] memory updates, bool[] memory replaceExisting)
        external
        pure
        returns (ITokenPoolV150.ChainUpdate[] memory)
    {
        return _toV150Updates(updates, replaceExisting);
    }

    function buildLaneUpdateCalls(
        PoolVersions.Version version,
        address poolAddress,
        uint64[] memory chainSelectorRemovals,
        TokenPool.ChainUpdate[] memory chainUpdates,
        bool[] memory replaceExisting
    ) external pure returns (CctActions.Call[] memory) {
        return _buildLaneUpdateCalls(version, poolAddress, chainSelectorRemovals, chainUpdates, replaceExisting);
    }
}

/// @notice Version-dispatch proofs for the pool scripts:
///         - the catalog: enum ordering, the UNKNOWN zero sentinel, and the full per-operation
///           capability-range table asserted cell by cell against the verified ABI surface;
///         - the resolver: happy paths per lineage prefix, the four named refusal classes
///           (not-a-pool, dev build, unknown version, foreign pool type) plus the
///           unsupported-for-operation refusal, each asserted on message content;
///         - POOL_VERSION_OVERRIDE: single and list parsing, malformed entries, and the loud
///           cross-check that aborts a wrong override (the env wiring is proven end to end in
///           AdoptTokenForkTest, the one test that sets the process-global env var);
///         - dispatch: the exhaustive lane-update switch for every cataloged version (byte-equal
///           calldata per shape) and the version-dispatched setRateLimits builder;
///         - read degradation: tryResolve never reverts, and the remote-pool getter dispatches
///           singular/plural per version with best effort on UNKNOWN.
contract PoolVersionDispatchTest is Test {
    uint64 internal constant SELECTOR = 8236463271206331221;
    address internal constant REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);
    address internal constant POOL = address(0x3333333333333333333333333333333333333333);

    ApplyChainUpdatesHarness internal harness;
    ResolverShim internal shim;

    function setUp() public {
        harness = new ApplyChainUpdatesHarness();
        shim = new ResolverShim();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Catalog: enum ordering, UNKNOWN sentinel, capability-range table
    // ─────────────────────────────────────────────────────────────────────────

    function test_Enum_OrderedWithUnknownZeroSentinel() public pure {
        assertEq(uint256(PoolVersions.Version.UNKNOWN), 0, "UNKNOWN must be the zero value");
        assertLt(uint256(PoolVersions.Version.UNKNOWN), uint256(PoolVersions.Version.V1_5_0), "UNKNOWN < 1.5.0");
        assertLt(uint256(PoolVersions.Version.V1_5_0), uint256(PoolVersions.Version.V1_5_1), "1.5.0 < 1.5.1");
        assertLt(uint256(PoolVersions.Version.V1_5_1), uint256(PoolVersions.Version.V1_6_1), "1.5.1 < 1.6.1");
        assertLt(uint256(PoolVersions.Version.V1_6_1), uint256(PoolVersions.Version.V2_0_0), "1.6.1 < 2.0.0");
    }

    function test_Enum_UnknownSupportsNothing() public pure {
        for (uint256 op = 0; op <= uint256(type(PoolVersions.Op).max); op++) {
            assertFalse(
                PoolVersions.isSupported(PoolVersions.Op(op), PoolVersions.Version.UNKNOWN),
                "UNKNOWN must support no operation"
            );
        }
    }

    /// @dev One assertion per (operation, version) cell. The expected rows re-encode the verified
    ///      per-version ABI surface independently of the range table, so a wrong range in
    ///      src/PoolVersions.sol fails here cell by cell. The two count assertions force this test
    ///      to be extended whenever a version or an operation is added.
    function test_CapabilityRangeTable_EveryCell() public pure {
        assertEq(uint256(type(PoolVersions.Version).max), 4, "new version added; extend the expected rows");
        assertEq(uint256(type(PoolVersions.Op).max), 19, "new operation added; extend the expected rows");

        // Rows are [V1_5_0, V1_5_1, V1_6_1, V2_0_0].
        _assertRow(PoolVersions.Op.APPLY_CHAIN_UPDATES, [false, true, true, true]);
        _assertRow(PoolVersions.Op.APPLY_CHAIN_UPDATES_V150, [true, false, false, false]);
        _assertRow(PoolVersions.Op.ADD_REMOTE_POOL, [false, true, true, true]);
        _assertRow(PoolVersions.Op.REMOVE_REMOTE_POOL, [false, true, true, true]);
        _assertRow(PoolVersions.Op.GET_REMOTE_POOLS, [false, true, true, true]);
        _assertRow(PoolVersions.Op.GET_REMOTE_POOL, [true, false, false, false]);
        _assertRow(PoolVersions.Op.SET_CHAIN_RATE_LIMITER_CONFIG, [true, true, true, false]);
        _assertRow(PoolVersions.Op.SET_RATE_LIMIT_CONFIG, [false, false, false, true]);
        _assertRow(PoolVersions.Op.SET_ROUTER, [true, true, true, false]);
        _assertRow(PoolVersions.Op.SET_RATE_LIMIT_ADMIN, [true, true, true, false]);
        _assertRow(PoolVersions.Op.SET_DYNAMIC_CONFIG, [false, false, false, true]);
        _assertRow(PoolVersions.Op.APPLY_ALLOW_LIST_UPDATES_POOL, [true, true, true, false]);
        _assertRow(PoolVersions.Op.SET_TOKEN_TRANSFER_FEE_CONFIG, [false, false, false, true]);
        _assertRow(PoolVersions.Op.SET_ALLOWED_FINALITY_CONFIG, [false, false, false, true]);
        _assertRow(PoolVersions.Op.APPLY_CCV_CONFIG, [false, false, false, true]);
        _assertRow(PoolVersions.Op.SET_CCV_THRESHOLD, [false, false, false, true]);
        // v1.x LockRelease rebalancer/liquidity surface: present 1.5.0/1.5.1/1.6.1, REMOVED in 2.0.0
        // (the external lock box replaced pool-held liquidity).
        _assertRow(PoolVersions.Op.GET_REBALANCER, [true, true, true, false]);
        _assertRow(PoolVersions.Op.SET_REBALANCER, [true, true, true, false]);
        _assertRow(PoolVersions.Op.PROVIDE_LIQUIDITY, [true, true, true, false]);
        _assertRow(PoolVersions.Op.WITHDRAW_LIQUIDITY, [true, true, true, false]);
    }

    function _assertRow(PoolVersions.Op op, bool[4] memory expected) internal pure {
        for (uint256 i = 0; i < 4; i++) {
            PoolVersions.Version v = PoolVersions.Version(i + 1);
            assertEq(
                PoolVersions.isSupported(op, v),
                expected[i],
                string.concat(PoolVersions.opName(op), " x ", PoolVersions.toString(v))
            );
        }
    }

    function test_VersionTokenRoundTrip() public pure {
        assertEq(uint256(PoolVersions.fromVersionToken("1.5.0")), uint256(PoolVersions.Version.V1_5_0), "1.5.0");
        assertEq(uint256(PoolVersions.fromVersionToken("1.5.1")), uint256(PoolVersions.Version.V1_5_1), "1.5.1");
        assertEq(uint256(PoolVersions.fromVersionToken("1.6.1")), uint256(PoolVersions.Version.V1_6_1), "1.6.1");
        assertEq(uint256(PoolVersions.fromVersionToken("2.0.0")), uint256(PoolVersions.Version.V2_0_0), "2.0.0");
        assertEq(uint256(PoolVersions.fromVersionToken("1.6.0")), uint256(PoolVersions.Version.UNKNOWN), "1.6.0");
        assertEq(uint256(PoolVersions.fromVersionToken("")), uint256(PoolVersions.Version.UNKNOWN), "empty");
        assertEq(PoolVersions.toString(PoolVersions.Version.V1_5_1), "1.5.1", "toString");
        assertEq(PoolVersions.toString(PoolVersions.Version.UNKNOWN), "unknown", "toString unknown");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Builder calldata (shapes unchanged by the dispatch rework)
    // ─────────────────────────────────────────────────────────────────────────

    function test_V150Builder_SelectorAndEncoding() public pure {
        ITokenPoolV150.ChainUpdate[] memory updates = _v150Add();
        CctActions.Call[] memory calls = CctActions.applyChainUpdatesV150(POOL, updates);

        assertEq(calls.length, 1, "one call");
        assertEq(calls[0].target, POOL, "target");
        assertEq(calls[0].value, 0, "value");
        assertEq(bytes4(calls[0].data), bytes4(0xdb6327dc), "1.5.0 applyChainUpdates selector");
        assertEq(
            calls[0].data,
            abi.encodeWithSelector(bytes4(0xdb6327dc), updates),
            "1.5.0 calldata mismatch vs hand-encoded expectation"
        );
    }

    function test_ModernBuilder_SelectorUnchanged() public pure {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        CctActions.Call[] memory calls = CctActions.applyChainUpdates(POOL, removes, updates);
        assertEq(bytes4(calls[0].data), bytes4(0xe8a1da17), "modern applyChainUpdates selector");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Resolver: happy paths
    // ─────────────────────────────────────────────────────────────────────────

    function test_Resolve_EveryLineagePrefixAndVersion() public {
        (PoolVersions.Version v, string memory full) =
            shim.resolve(address(new MockTypeAndVersion("BurnMintTokenPool 1.5.0")));
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_5_0), "BurnMint 1.5.0");
        assertEq(full, "BurnMintTokenPool 1.5.0", "full string returned");

        (v,) = shim.resolve(address(new MockTypeAndVersion("BurnFromMintTokenPool 1.5.1")));
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_5_1), "BurnFromMint 1.5.1");

        (v,) = shim.resolve(address(new MockTypeAndVersion("BurnWithFromMintTokenPool 1.6.1")));
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_6_1), "BurnWithFromMint 1.6.1");

        (v,) = shim.resolve(address(new MockTypeAndVersion("LockReleaseTokenPool 2.0.0")));
        assertEq(uint256(v), uint256(PoolVersions.Version.V2_0_0), "LockRelease 2.0.0");
    }

    function test_Resolve_TrimsTrailingWhitespace() public {
        (PoolVersions.Version v,) = shim.resolve(address(new MockTypeAndVersion("BurnMintTokenPool 2.0.0 ")));
        assertEq(uint256(v), uint256(PoolVersions.Version.V2_0_0), "trailing space tolerated");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Resolver: the four refusal classes, asserted on message content
    // ─────────────────────────────────────────────────────────────────────────

    function test_Refusal_NotAPool() public {
        address none = address(new NoTypeAndVersion());
        string memory reason = _catchResolve(none);
        _assertContains(reason, "NotACcipTokenPool");
        _assertContains(reason, vm.toString(none));
        _assertContains(reason, "not a CCIP token pool");
        _assertContains(reason, "token address instead of the pool");
    }

    function test_Refusal_NotAPool_CodelessAddress() public {
        // A call to a codeless address returns empty data and the string decode is uncatchable, so
        // the resolver must check code length first and refuse by name.
        address codeless = address(uint160(uint256(keccak256("codeless-address-fixture"))));
        string memory reason = _catchResolve(codeless);
        _assertContains(reason, "NotACcipTokenPool");
        _assertContains(reason, "not a CCIP token pool");

        (bool ok, PoolVersions.Version v,) = shim.tryResolve(codeless);
        assertFalse(ok, "codeless address degrades on read paths");
        assertEq(uint256(v), uint256(PoolVersions.Version.UNKNOWN), "codeless address is UNKNOWN");
    }

    function test_Refusal_DevBuild() public {
        address dev = address(new MockTypeAndVersion("BurnMintTokenPool 1.6.3-dev"));
        string memory reason = _catchResolve(dev);
        _assertContains(reason, "DevBuildRefused");
        _assertContains(reason, vm.toString(dev));
        _assertContains(reason, "BurnMintTokenPool 1.6.3-dev");
        _assertContains(reason, "POOL_VERSION_OVERRIDE");
        _assertContains(reason, "docs/pool-versions.md#dev-builds");
    }

    function test_Refusal_UnknownVersion() public {
        address unknown = address(new MockTypeAndVersion("BurnMintTokenPool 1.6.0"));
        string memory reason = _catchResolve(unknown);
        _assertContains(reason, "UnsupportedPoolVersion");
        _assertContains(reason, vm.toString(unknown));
        _assertContains(reason, "BurnMintTokenPool 1.6.0");
        _assertContains(reason, "1.5.0, 1.5.1, 1.6.1, 2.0.0");
        _assertContains(reason, "npm package versions are not pool versions");
        _assertContains(reason, "POOL_VERSION_OVERRIDE");
        _assertContains(reason, "docs/pool-versions.md#unknown-versions");
    }

    function test_Refusal_FutureVersion() public {
        // A plausible future release is refused through the same unknown-version class, which
        // names the override and the catalog as the two exits.
        address future = address(new MockTypeAndVersion("BurnMintTokenPool 2.1.0"));
        string memory reason = _catchResolve(future);
        _assertContains(reason, "UnsupportedPoolVersion");
        _assertContains(reason, "2.1.0");
        _assertContains(reason, "src/PoolVersions.sol");
    }

    function test_Refusal_ForeignTypePrefix() public {
        // USDCTokenPool versions independently: its 1.5.1 is NOT TokenPool 1.5.1.
        address usdc = address(new MockTypeAndVersion("USDCTokenPool 1.5.1"));
        string memory reason = _catchResolve(usdc);
        _assertContains(reason, "UnsupportedPoolType");
        _assertContains(reason, "USDCTokenPool 1.5.1");
        _assertContains(reason, "TokenPool lineage");
        _assertContains(reason, "POOL_VERSION_OVERRIDE");
    }

    function test_Refusal_UnsupportedOperation() public {
        // The v1 rate-limit setter was REMOVED in 2.0.0: a floor check would wrongly pass here.
        try shim.requireSupports(PoolVersions.Op.SET_CHAIN_RATE_LIMITER_CONFIG, PoolVersions.Version.V2_0_0, POOL) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "UnsupportedPoolOperation");
            _assertContains(reason, "setChainRateLimiterConfig");
            _assertContains(reason, "2.0.0");
            _assertContains(reason, "1.5.0 up to but not including 2.0.0");
            _assertContains(reason, "docs/pool-versions.md#operation-ranges");
        }

        // The 1.5.1 boundary in the other direction.
        try shim.requireSupports(PoolVersions.Op.ADD_REMOTE_POOL, PoolVersions.Version.V1_5_0, POOL) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "UnsupportedPoolOperation");
            _assertContains(reason, "addRemotePool");
            _assertContains(reason, "1.5.1 and later");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // POOL_VERSION_OVERRIDE: parsing, warning path, cross-check
    // ─────────────────────────────────────────────────────────────────────────

    function test_Override_SingleEntry_ReturnsCatalogedVersionAndTrueString() public {
        address pool = address(new MockV1SurfaceDevPool());
        (PoolVersions.Version v, string memory full) =
            shim.resolveWith(pool, string.concat(vm.toString(pool), "=1.6.1"));
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_6_1), "override version honored");
        assertEq(full, "LockReleaseTokenPool 1.6.x-dev", "the TRUE on-chain string is returned, not the alias");
    }

    function test_Override_CommaSeparatedList() public {
        address pool = address(new MockV1SurfaceDevPool());
        string memory spec =
            string.concat("0x1111111111111111111111111111111111111111=2.0.0,", vm.toString(pool), "=1.5.1");
        (PoolVersions.Version v,) = shim.resolveWith(pool, spec);
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_5_1), "matching list entry honored");
    }

    function test_Override_NoMatchingEntry_NormalRefusalStillNames() public {
        address pool = address(new MockV1SurfaceDevPool());
        // A valid entry for a DIFFERENT address leaves this pool on the normal refusal path.
        try shim.resolveWith(pool, "0x1111111111111111111111111111111111111111=2.0.0") {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "DevBuildRefused");
        }
    }

    function test_Override_Malformed_NoEquals() public {
        address pool = address(new MockV1SurfaceDevPool());
        _assertMalformedOverride(pool, "banana");
    }

    function test_Override_Malformed_UncatalogedVersion() public {
        address pool = address(new MockV1SurfaceDevPool());
        _assertMalformedOverride(pool, string.concat(vm.toString(pool), "=9.9.9"));
    }

    function test_Override_Malformed_BadAddress() public {
        address pool = address(new MockV1SurfaceDevPool());
        _assertMalformedOverride(pool, "nope=1.5.0");
    }

    function test_Override_Malformed_AnyEntryAborts() public {
        // A malformed entry anywhere in the list aborts, also when another entry would match.
        address pool = address(new MockV1SurfaceDevPool());
        _assertMalformedOverride(pool, string.concat("garbage,", vm.toString(pool), "=1.6.1"));
    }

    function _assertMalformedOverride(address pool, string memory spec) internal {
        try shim.resolveWith(pool, spec) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "PoolVersionOverrideMalformed");
            _assertContains(reason, "docs/pool-versions.md#overrides");
        }
    }

    function test_Override_CrossCheck_AbortsWhenV2ClaimHasNoV2Getter() public {
        // Pool answers only the v1 getter; an override claiming 2.0.0 must abort with a diagnostic.
        address pool = address(new MockV1SurfaceDevPool());
        try shim.resolveWith(pool, string.concat(vm.toString(pool), "=2.0.0")) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "PoolVersionOverrideMismatch");
            _assertContains(reason, "getCurrentRateLimiterState(uint64,bool) does not answer");
            _assertContains(reason, "LockReleaseTokenPool 1.6.x-dev");
        }
    }

    function test_Override_CrossCheck_AbortsWhenV1ClaimHasNoV1Getter() public {
        // Pool answers only the v2 getter; an override claiming a pre-2.0 version must abort.
        address pool = address(new MockV2SurfaceFuturePool());
        try shim.resolveWith(pool, string.concat(vm.toString(pool), "=1.6.1")) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "PoolVersionOverrideMismatch");
            _assertContains(reason, "getCurrentOutboundRateLimiterState(uint64) does not answer");
        }
    }

    function test_Override_CrossCheck_PassesWhenSurfaceAgrees() public {
        // A future 2.1.0 pool asserted as 2.0.0: the v2 getter answers, so the override is honored.
        address pool = address(new MockV2SurfaceFuturePool());
        (PoolVersions.Version v, string memory full) =
            shim.resolveWith(pool, string.concat(vm.toString(pool), "=2.0.0"));
        assertEq(uint256(v), uint256(PoolVersions.Version.V2_0_0), "cross-checked override honored");
        assertEq(full, "BurnMintTokenPool 2.1.0", "true string preserved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lane-update dispatch: exhaustive switch over the catalog
    // ─────────────────────────────────────────────────────────────────────────

    function test_LaneUpdateDispatch_V150TakesLegacyShape() public view {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bool[] memory replaceExisting = new bool[](1);
        replaceExisting[0] = true;

        CctActions.Call[] memory calls =
            harness.buildLaneUpdateCalls(PoolVersions.Version.V1_5_0, POOL, removes, updates, replaceExisting);

        assertEq(calls.length, 1, "one call");
        assertEq(bytes4(calls[0].data), bytes4(0xdb6327dc), "1.5.0 selector");
        assertEq(
            calls[0].data,
            CctActions.applyChainUpdatesV150(POOL, harness.convert(updates, replaceExisting))[0].data,
            "1.5.0 dispatch calldata byte-equal to the direct builder"
        );
    }

    function test_LaneUpdateDispatch_ModernVersionsShareOneShape() public view {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bool[] memory replaceExisting = new bool[](1);
        bytes memory expected = CctActions.applyChainUpdates(POOL, removes, updates)[0].data;

        PoolVersions.Version[3] memory modern =
            [PoolVersions.Version.V1_5_1, PoolVersions.Version.V1_6_1, PoolVersions.Version.V2_0_0];
        for (uint256 i = 0; i < modern.length; i++) {
            CctActions.Call[] memory calls =
                harness.buildLaneUpdateCalls(modern[i], POOL, removes, updates, replaceExisting);
            assertEq(bytes4(calls[0].data), bytes4(0xe8a1da17), "modern selector");
            assertEq(
                calls[0].data,
                expected,
                string.concat("modern dispatch calldata byte-equal for ", PoolVersions.toString(modern[i]))
            );
        }
    }

    function test_LaneUpdateDispatch_UnknownHitsNoBranch() public {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bool[] memory replaceExisting = new bool[](1);

        try harness.buildLaneUpdateCalls(PoolVersions.Version.UNKNOWN, POOL, removes, updates, replaceExisting) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "no lane-update dispatch branch");
            _assertContains(reason, "src/PoolVersions.sol");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // setRateLimits: version-dispatched builder (calldata byte equality)
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetRateLimits_V1RangeTakesV1Setter_ByteEqual() public view {
        RateLimiter.Config memory out = _cfg(true, 1_000e18, 10e18);
        RateLimiter.Config memory inb = _cfg(true, 2_000e18, 20e18);
        bytes memory expected = abi.encodeWithSignature(
            "setChainRateLimiterConfig(uint64,(bool,uint128,uint128),(bool,uint128,uint128))", SELECTOR, out, inb
        );

        PoolVersions.Version[3] memory v1Range =
            [PoolVersions.Version.V1_5_0, PoolVersions.Version.V1_5_1, PoolVersions.Version.V1_6_1];
        for (uint256 i = 0; i < v1Range.length; i++) {
            CctActions.Call[] memory calls = shim.setRateLimits(POOL, v1Range[i], SELECTOR, false, out, inb);
            assertEq(calls.length, 1, "one call");
            assertEq(calls[0].target, POOL, "target");
            assertEq(
                calls[0].data,
                expected,
                string.concat("v1 setter calldata byte-equal for ", PoolVersions.toString(v1Range[i]))
            );
        }
    }

    function test_SetRateLimits_V2TakesV2Setter_ByteEqual() public view {
        RateLimiter.Config memory out = _cfg(true, 1_000e18, 10e18);
        RateLimiter.Config memory inb = _cfg(false, 0, 0);

        TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
        args[0] = TokenPool.RateLimitConfigArgs({
            remoteChainSelector: SELECTOR,
            fastFinality: true,
            outboundRateLimiterConfig: out,
            inboundRateLimiterConfig: inb
        });

        CctActions.Call[] memory calls = shim.setRateLimits(POOL, PoolVersions.Version.V2_0_0, SELECTOR, true, out, inb);
        assertEq(calls[0].data, abi.encodeCall(TokenPool.setRateLimitConfig, (args)), "v2 setter calldata");
    }

    function test_SetRateLimits_UnknownRefusesByName() public {
        RateLimiter.Config memory cfg = _cfg(false, 0, 0);
        try shim.setRateLimits(POOL, PoolVersions.Version.UNKNOWN, SELECTOR, false, cfg, cfg) {
            fail();
        } catch Error(string memory reason) {
            _assertContains(reason, "UnsupportedPoolOperation");
            _assertContains(reason, "setChainRateLimiterConfig");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Read-path degradation: tryResolve and the remote-pool getter dispatch
    // ─────────────────────────────────────────────────────────────────────────

    function test_TryResolve_NeverRevertsAndDegrades() public {
        (bool ok, PoolVersions.Version v, string memory full) = shim.tryResolve(address(new NoTypeAndVersion()));
        assertFalse(ok, "non-pool degrades");
        assertEq(uint256(v), uint256(PoolVersions.Version.UNKNOWN), "non-pool is UNKNOWN");
        assertEq(full, "", "no string available");

        (ok, v, full) = shim.tryResolve(address(new MockTypeAndVersion("BurnMintTokenPool 1.6.3-dev")));
        assertFalse(ok, "dev build degrades on read paths");
        assertEq(uint256(v), uint256(PoolVersions.Version.UNKNOWN), "dev build is UNKNOWN");
        assertEq(full, "BurnMintTokenPool 1.6.3-dev", "raw string surfaced for the warning");

        (ok, v, full) = shim.tryResolve(address(new MockTypeAndVersion("USDCTokenPool 1.5.1")));
        assertFalse(ok, "foreign type prefix degrades on read paths");

        (ok, v, full) = shim.tryResolve(address(new MockTypeAndVersion("LockReleaseTokenPool 2.0.0")));
        assertTrue(ok, "cataloged version resolves");
        assertEq(uint256(v), uint256(PoolVersions.Version.V2_0_0), "resolved version");
    }

    function test_RemotePoolsRead_SingularGetterOn150() public {
        bytes memory encoded = abi.encode(REMOTE_POOL);
        address pool150 = address(new Mock150Pool(encoded));

        bytes[] memory pools = shim.remotePools(pool150, PoolVersions.Version.V1_5_0, SELECTOR);
        assertEq(pools.length, 1, "singular getter wrapped");
        assertEq(pools[0], encoded, "singular getter value");
    }

    function test_RemotePoolsRead_PluralGetterFrom151() public {
        bytes memory encoded = abi.encode(REMOTE_POOL);
        address modern = address(new MockModernPool(encoded));

        bytes[] memory pools = shim.remotePools(modern, PoolVersions.Version.V1_6_1, SELECTOR);
        assertEq(pools.length, 1, "plural getter");
        assertEq(pools[0], encoded, "plural getter value");
    }

    function test_RemotePoolsRead_UnknownFallsBack() public {
        bytes memory encoded = abi.encode(REMOTE_POOL);

        // UNKNOWN on a plural-surface pool: the plural getter answers first.
        bytes[] memory pools =
            shim.remotePools(address(new MockModernPool(encoded)), PoolVersions.Version.UNKNOWN, SELECTOR);
        assertEq(pools[0], encoded, "best effort prefers the plural getter");

        // UNKNOWN on a singular-only (1.5.0-shaped) pool: falls back to the singular getter.
        pools = shim.remotePools(address(new Mock150Pool(encoded)), PoolVersions.Version.UNKNOWN, SELECTOR);
        assertEq(pools.length, 1, "best effort falls back to the singular getter");
        assertEq(pools[0], encoded, "fallback value");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Modern-to-1.5.0 conversion
    // ─────────────────────────────────────────────────────────────────────────

    function test_Convert_NewLane_SingleAllowedEntry() public view {
        (, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bool[] memory replaceExisting = new bool[](1);

        ITokenPoolV150.ChainUpdate[] memory out = harness.convert(updates, replaceExisting);

        assertEq(out.length, 1, "one entry for a new lane");
        assertTrue(out[0].allowed, "allowed");
        assertEq(out[0].remoteChainSelector, SELECTOR, "selector");
        assertEq(out[0].remotePoolAddress, abi.encode(REMOTE_POOL), "remote pool");
        assertEq(out[0].remoteTokenAddress, abi.encode(REMOTE_TOKEN), "remote token");
    }

    function test_Convert_Replacement_RemoveBeforeAdd() public view {
        (, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bool[] memory replaceExisting = new bool[](1);
        replaceExisting[0] = true;

        ITokenPoolV150.ChainUpdate[] memory out = harness.convert(updates, replaceExisting);

        assertEq(out.length, 2, "removal entry plus add entry");
        assertFalse(out[0].allowed, "removal first");
        assertEq(out[0].remoteChainSelector, SELECTOR, "removal selector");
        assertFalse(out[0].outboundRateLimiterConfig.isEnabled, "removal outbound config disabled");
        assertFalse(out[0].inboundRateLimiterConfig.isEnabled, "removal inbound config disabled");
        assertTrue(out[1].allowed, "add second");
        assertEq(out[1].remotePoolAddress, abi.encode(REMOTE_POOL), "add remote pool");
    }

    function test_Convert_RejectsMultiplePools() public {
        (, TokenPool.ChainUpdate[] memory updates) = _modernAdd();
        bytes[] memory two = new bytes[](2);
        two[0] = abi.encode(REMOTE_POOL);
        two[1] = abi.encode(REMOTE_TOKEN);
        updates[0].remotePoolAddresses = two;
        bool[] memory replaceExisting = new bool[](1);

        vm.expectRevert(
            bytes(
                string.concat(
                    "Pool contract version 1.5.0 supports exactly one remote pool per chain; got 2 for selector ",
                    vm.toString(SELECTOR)
                )
            )
        );
        harness.convert(updates, replaceExisting);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev External-call shim for revert capture: resolve through the shim, return the reason.
    function _catchResolve(address pool) internal view returns (string memory reason) {
        try shim.resolve(pool) {
            revert("resolve unexpectedly succeeded");
        } catch Error(string memory r) {
            return r;
        }
    }

    function _assertContains(string memory haystack, string memory needle) internal pure {
        assertTrue(_contains(haystack, needle), string.concat("expected \"", needle, "\" in: ", haystack));
    }

    function _contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function _cfg(bool enabled, uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: enabled, capacity: capacity, rate: rate});
    }

    function _v150Add() internal pure returns (ITokenPoolV150.ChainUpdate[] memory updates) {
        updates = new ITokenPoolV150.ChainUpdate[](1);
        updates[0] = ITokenPoolV150.ChainUpdate({
            remoteChainSelector: SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(REMOTE_POOL),
            remoteTokenAddress: abi.encode(REMOTE_TOKEN),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
    }

    function _modernAdd() internal pure returns (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) {
        removes = new uint64[](0);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(REMOTE_POOL);
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: SELECTOR,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(REMOTE_TOKEN),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
    }
}

/// @notice Fence-order proof for AddRemotePool: against a 1.5.0-shaped pool (no plural
///         getRemotePools at all) the script must refuse with the NAMED unsupported-operation
///         message BEFORE its remote-pool read runs. A raw selector revert here would mean the
///         read moved back in front of the version fence. The pool is injected through the
///         harness seam; no process-global env var is touched.
contract AddRemotePoolFenceForkTest is BaseForkTest {
    uint64 internal constant MANTLE_SEPOLIA_SELECTOR = 8236463271206331221;

    function test_AddRemotePool_150Pool_NamedRefusalBeforeRead() public {
        Mock150Pool pool150 = new Mock150Pool(abi.encode(address(0x1111)));
        AddRemotePoolHarness script = new AddRemotePoolHarness();

        // Error(string) proves the refusal is the curated message, not a raw EvmError from the
        // absent getRemotePools selector (which would not decode as Error(string)).
        try script.invoke(
            address(pool150),
            address(0x4444444444444444444444444444444444444444),
            MANTLE_SEPOLIA_SELECTOR,
            "MANTLE_SEPOLIA",
            5003
        ) {
            revert("AddRemotePool unexpectedly succeeded on a 1.5.0 pool");
        } catch Error(string memory reason) {
            assertTrue(_reasonNamesTheFence(reason), reason);
        }
    }

    function _reasonNamesTheFence(string memory reason) internal pure returns (bool) {
        bytes memory b = bytes(reason);
        bytes memory n = bytes("UnsupportedPoolOperation: addRemotePool");
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}

/// @notice Fence-order proof for RemoveRemotePool, mirroring the AddRemotePool proof: a 1.5.0
///         pool must get the NAMED unsupported-operation refusal before the script's
///         isRemotePool/getRemotePools reads (both absent on 1.5.0) run.
contract RemoveRemotePoolFenceForkTest is BaseForkTest {
    uint64 internal constant MANTLE_SEPOLIA_SELECTOR = 8236463271206331221;

    function test_RemoveRemotePool_150Pool_NamedRefusalBeforeRead() public {
        Mock150Pool pool150 = new Mock150Pool(abi.encode(address(0x1111)));
        RemoveRemotePoolHarness script = new RemoveRemotePoolHarness();

        // Error(string) proves the refusal is the curated message, not a raw EvmError from the
        // absent isRemotePool/getRemotePools selectors (which would not decode as Error(string)).
        try script.invoke(
            address(pool150),
            address(0x4444444444444444444444444444444444444444),
            MANTLE_SEPOLIA_SELECTOR,
            "MANTLE_SEPOLIA",
            5003
        ) {
            revert("RemoveRemotePool unexpectedly succeeded on a 1.5.0 pool");
        } catch Error(string memory reason) {
            assertTrue(_reasonNamesTheFence(reason), reason);
        }
    }

    function _reasonNamesTheFence(string memory reason) internal pure returns (bool) {
        bytes memory b = bytes(reason);
        bytes memory n = bytes("UnsupportedPoolOperation: removeRemotePool");
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
