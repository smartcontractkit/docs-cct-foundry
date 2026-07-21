// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {CctActions, IRateLimiterV1} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @dev A minimal pool that exposes ONLY the v1.x rate-limiter surface (`setChainRateLimiterConfig` +
///      the two per-direction getters) and NOT the v2 `getCurrentRateLimiterState(uint64,bool)` getter.
///      It faithfully stores the config the v1 setter writes, so the v1 dispatch path can be
///      fork-executed and read back - the 1.6.x generation is not in this repo's dependency set,
///      so a minimal faithful v1 ABI is the honest way to prove the dual-generation dispatch
///      routes correctly.
contract MockV1RateLimiterPool {
    address public owner;

    mapping(uint64 => RateLimiter.TokenBucket) internal s_outbound;
    mapping(uint64 => RateLimiter.TokenBucket) internal s_inbound;

    constructor() {
        owner = msg.sender;
    }

    function setChainRateLimiterConfig(
        uint64 remoteChainSelector,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) external {
        require(msg.sender == owner, "not owner");
        s_outbound[remoteChainSelector] = RateLimiter.TokenBucket({
            tokens: outbound.capacity,
            lastUpdated: 0,
            isEnabled: outbound.isEnabled,
            capacity: outbound.capacity,
            rate: outbound.rate
        });
        s_inbound[remoteChainSelector] = RateLimiter.TokenBucket({
            tokens: inbound.capacity,
            lastUpdated: 0,
            isEnabled: inbound.isEnabled,
            capacity: inbound.capacity,
            rate: inbound.rate
        });
    }

    function getCurrentOutboundRateLimiterState(uint64 sel) external view returns (RateLimiter.TokenBucket memory) {
        return s_outbound[sel];
    }

    function getCurrentInboundRateLimiterState(uint64 sel) external view returns (RateLimiter.TokenBucket memory) {
        return s_inbound[sel];
    }
}

/// @dev A BurnMintTokenPool subclass that exposes the internal fast-finality consume path so the
///      fallback behaviour (fast bucket disabled -> default bucket consumed, TokenPool.sol
///      `_consumeFastFinalityOutboundRateLimit`) can be exercised without a full cross-chain send.
contract FastFinalityProbePool is BurnMintTokenPool {
    constructor(IBurnMintERC20 token, uint8 decimals, address rmnProxy, address router)
        BurnMintTokenPool(token, decimals, address(0), rmnProxy, router)
    {}

    function probeFastOutbound(uint64 remoteChainSelector, uint256 amount) external {
        _consumeFastFinalityOutboundRateLimit(address(getToken()), remoteChainSelector, amount);
    }
}

/// @notice Fork parity tests for the `configure/*` write-script groups.
/// Each operation is exercised through its `CctActions` builder (the exact `Call[]` the scripts
/// hand to `EoaExecutor`), then asserted against the pool's on-chain getters.
contract ConfigureActionsForkTest is BaseForkTest {
    uint64 internal constant SELECTOR = 8236463271206331221; // Mantle Sepolia
    address internal constant REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);

    address internal token;
    address internal pool;
    address internal owner;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        owner = _scriptBroadcaster();
        _addLane(owner, pool, SELECTOR, REMOTE_POOL, REMOTE_TOKEN);
    }

    // ── Lane bootstrap ────────────────────────────────────────────────────────

    function _addLane(address asOwner, address p, uint64 selector, address remotePool, address remoteToken) internal {
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(remotePool);
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: selector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        _exec(asOwner, CctActions._applyChainUpdates(p, new uint64[](0), updates));
    }

    function _cfg(bool enabled, uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: enabled, capacity: capacity, rate: rate});
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rate limits - standard and fast-finality buckets, asserted via getters
    // ─────────────────────────────────────────────────────────────────────────

    function test_RateLimits_StandardBucket_ViaGetter() public {
        RateLimiter.Config memory out = _cfg(true, 1_000e18, 10e18);
        RateLimiter.Config memory inb = _cfg(true, 2_000e18, 20e18);

        _exec(owner, CctActions._setRateLimits(pool, PoolVersions.Version.V2_0_0, SELECTOR, false, out, inb));

        (RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i) =
            TokenPool(pool).getCurrentRateLimiterState(SELECTOR, false);
        assertTrue(o.isEnabled, "outbound enabled");
        assertEq(o.capacity, 1_000e18, "outbound capacity");
        assertEq(o.rate, 10e18, "outbound rate");
        assertTrue(i.isEnabled, "inbound enabled");
        assertEq(i.capacity, 2_000e18, "inbound capacity");
        assertEq(i.rate, 20e18, "inbound rate");
    }

    function test_RateLimits_FastFinalityBucket_ViaGetter() public {
        RateLimiter.Config memory out = _cfg(true, 500e18, 5e18);
        RateLimiter.Config memory inb = _cfg(false, 0, 0);

        _exec(owner, CctActions._setRateLimits(pool, PoolVersions.Version.V2_0_0, SELECTOR, true, out, inb));

        (RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i) =
            TokenPool(pool).getCurrentRateLimiterState(SELECTOR, true);
        assertTrue(o.isEnabled, "fast outbound enabled");
        assertEq(o.capacity, 500e18, "fast outbound capacity");
        assertFalse(i.isEnabled, "fast inbound disabled");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Version-dispatched setters - 1.5.0-1.6.1 -> v1 setter, 2.0.0 -> v2 setter
    // ─────────────────────────────────────────────────────────────────────────

    function test_VersionDispatch_V1Calldata() public {
        MockV1RateLimiterPool v1 = new MockV1RateLimiterPool();
        RateLimiter.Config memory out = _cfg(true, 2, 1);
        RateLimiter.Config memory inb = _cfg(true, 100_000e18, 100e18);

        CctActions.Call[] memory calls =
            CctActions._setRateLimits(address(v1), PoolVersions.Version.V1_6_1, SELECTOR, false, out, inb);
        assertEq(calls.length, 1, "v1 dispatch is one call");
        assertEq(calls[0].target, address(v1), "targets the v1 pool");
        assertEq(
            calls[0].data,
            abi.encodeCall(IRateLimiterV1.setChainRateLimiterConfig, (SELECTOR, out, inb)),
            "v1 setter calldata"
        );
        assertEq(bytes4(calls[0].data), IRateLimiterV1.setChainRateLimiterConfig.selector, "v1 selector");
    }

    function test_VersionDispatch_V2Calldata() public view {
        RateLimiter.Config memory out = _cfg(true, 2, 1);
        RateLimiter.Config memory inb = _cfg(true, 100_000e18, 100e18);

        TokenPool.RateLimitConfigArgs[] memory expected = new TokenPool.RateLimitConfigArgs[](1);
        expected[0] = TokenPool.RateLimitConfigArgs({
            remoteChainSelector: SELECTOR,
            fastFinality: false,
            outboundRateLimiterConfig: out,
            inboundRateLimiterConfig: inb
        });

        CctActions.Call[] memory calls =
            CctActions._setRateLimits(pool, PoolVersions.Version.V2_0_0, SELECTOR, false, out, inb);
        assertEq(calls[0].target, pool, "targets the v2 pool");
        assertEq(calls[0].data, abi.encodeCall(TokenPool.setRateLimitConfig, (expected)), "v2 setter calldata");
    }

    function test_VersionDispatch_V1SetterOnV2PoolReverts() public {
        RateLimiter.Config memory out = _cfg(true, 1e18, 1e18);
        // Force the v1 calldata (a v1-range version) but aim it at the real 2.0.0 pool: the selector
        // does not exist there.
        CctActions.Call[] memory calls =
            CctActions._setRateLimits(pool, PoolVersions.Version.V1_6_1, SELECTOR, false, out, out);
        vm.prank(owner);
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertFalse(ok, "v1 setter must not exist on a 2.0.0 pool");
    }

    function test_VersionDispatch_V1ForkExecution() public {
        MockV1RateLimiterPool v1 = new MockV1RateLimiterPool(); // deployed by this test => test is owner
        RateLimiter.Config memory out = _cfg(true, 2, 1);
        RateLimiter.Config memory inb = _cfg(true, 100_000e18, 100e18);

        _exec(
            address(this),
            CctActions._setRateLimits(address(v1), PoolVersions.Version.V1_6_1, SELECTOR, false, out, inb)
        );

        RateLimiter.TokenBucket memory o = v1.getCurrentOutboundRateLimiterState(SELECTOR);
        assertTrue(o.isEnabled, "v1 outbound enabled");
        assertEq(o.capacity, 2, "v1 outbound capacity");
        assertEq(o.rate, 1, "v1 outbound rate");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Remote pools - getRemotePools
    // ─────────────────────────────────────────────────────────────────────────

    function test_AddRemotePool_ViaGetter() public {
        address extraPool = address(0x3333333333333333333333333333333333333333);
        uint256 before = TokenPool(pool).getRemotePools(SELECTOR).length;

        _exec(owner, CctActions._addRemotePool(pool, SELECTOR, abi.encode(extraPool)));

        bytes[] memory pools = TokenPool(pool).getRemotePools(SELECTOR);
        assertEq(pools.length, before + 1, "remote pool count grew");
        assertTrue(TokenPool(pool).isRemotePool(SELECTOR, abi.encode(extraPool)), "new remote pool registered");

        _exec(owner, CctActions._removeRemotePool(pool, SELECTOR, abi.encode(extraPool)));
        assertFalse(TokenPool(pool).isRemotePool(SELECTOR, abi.encode(extraPool)), "remote pool removed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dynamic config - getDynamicConfig
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetDynamicConfig_ViaGetter() public {
        address rla = address(0xA11CE);
        address fa = address(0xBEEF);
        _exec(owner, CctActions._setDynamicConfig(pool, networkConfig.router, rla, fa));

        (address router, address rateLimitAdmin, address feeAdmin) = TokenPool(pool).getDynamicConfig();
        assertEq(router, networkConfig.router, "router set");
        assertEq(rateLimitAdmin, rla, "rate limit admin set");
        assertEq(feeAdmin, fa, "fee admin set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Finality matrix - getAllowedFinalityConfig (four modes)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Finality_ModeBlockDepth() public {
        _exec(owner, CctActions._setAllowedFinalityConfig(pool, FinalityCodec._encodeBlockDepth(5)));
        assertEq(TokenPool(pool).getAllowedFinalityConfig(), bytes4(0x00000005), "block-depth 5");
    }

    function test_Finality_ModeWaitForSafe() public {
        _exec(owner, CctActions._setAllowedFinalityConfig(pool, FinalityCodec.WAIT_FOR_SAFE_FLAG));
        assertEq(TokenPool(pool).getAllowedFinalityConfig(), bytes4(0x00010000), "wait-for-safe");
    }

    function test_Finality_ModeCombined() public {
        _exec(owner, CctActions._setAllowedFinalityConfig(pool, FinalityCodec._encodeBlockDepthAndSafeFlag(5)));
        assertEq(TokenPool(pool).getAllowedFinalityConfig(), bytes4(0x00010005), "combined depth|safe");
    }

    function test_Finality_ModeResetToDefault() public {
        _exec(owner, CctActions._setAllowedFinalityConfig(pool, FinalityCodec._encodeBlockDepthAndSafeFlag(5)));
        _exec(owner, CctActions._setAllowedFinalityConfig(pool, FinalityCodec.WAIT_FOR_FINALITY_FLAG));
        assertEq(TokenPool(pool).getAllowedFinalityConfig(), bytes4(0x00000000), "reset to default");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fee config - getTokenTransferFeeConfig (the getter the script uses)
    // ─────────────────────────────────────────────────────────────────────────

    function test_FeeConfig_EnableThenDisable_ViaGetter() public {
        TokenPool.TokenTransferFeeConfigArgs[] memory args = new TokenPool.TokenTransferFeeConfigArgs[](1);
        args[0] = TokenPool.TokenTransferFeeConfigArgs({
            destChainSelector: SELECTOR,
            tokenTransferFeeConfig: IPoolV2.TokenTransferFeeConfig({
                destGasOverhead: 50_000,
                destBytesOverhead: 0,
                finalityFeeUSDCents: 0,
                fastFinalityFeeUSDCents: 100,
                finalityTransferFeeBps: 0,
                fastFinalityTransferFeeBps: 50,
                isEnabled: true
            })
        });
        _exec(owner, CctActions._applyTokenTransferFeeConfigUpdates(pool, args, new uint64[](0)));

        IPoolV2.TokenTransferFeeConfig memory cfg =
            TokenPool(pool).getTokenTransferFeeConfig(address(0), SELECTOR, 0, "");
        assertTrue(cfg.isEnabled, "fee config enabled");
        assertEq(cfg.destGasOverhead, 50_000, "gas overhead");
        assertEq(cfg.fastFinalityFeeUSDCents, 100, "fast finality fee");
        assertEq(cfg.fastFinalityTransferFeeBps, 50, "fast finality bps");

        uint64[] memory disable = new uint64[](1);
        disable[0] = SELECTOR;
        _exec(
            owner,
            CctActions._applyTokenTransferFeeConfigUpdates(pool, new TokenPool.TokenTransferFeeConfigArgs[](0), disable)
        );

        cfg = TokenPool(pool).getTokenTransferFeeConfig(address(0), SELECTOR, 0, "");
        assertFalse(cfg.isEnabled, "fee config disabled");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fast-finality fallback (behavioural): fast bucket disabled + default enabled ->
    // a fast-finality transfer consumes the DEFAULT bucket (TokenPool.sol
    // _consumeFastFinalityOutboundRateLimit). Leaving the fast bucket unconfigured is safe.
    // ─────────────────────────────────────────────────────────────────────────

    function test_FastFinalityFallback_ConsumesDefaultBucket() public {
        FastFinalityProbePool probe =
            new FastFinalityProbePool(IBurnMintERC20(token), 18, networkConfig.rmnProxy, networkConfig.router);
        // This test contract is the probe pool's owner.
        _addLane(address(this), address(probe), SELECTOR, REMOTE_POOL, REMOTE_TOKEN);

        // Default (standard) outbound bucket enabled; fast-finality bucket left UNCONFIGURED (disabled).
        _exec(
            address(this),
            CctActions._setRateLimits(
                address(probe),
                PoolVersions.Version.V2_0_0,
                SELECTOR,
                false,
                _cfg(true, 1_000e18, 10e18),
                _cfg(false, 0, 0)
            )
        );

        (RateLimiter.TokenBucket memory defBefore,) = probe.getCurrentRateLimiterState(SELECTOR, false);
        (RateLimiter.TokenBucket memory fastBefore,) = probe.getCurrentRateLimiterState(SELECTOR, true);
        assertTrue(defBefore.isEnabled, "default bucket enabled");
        assertFalse(fastBefore.isEnabled, "fast bucket unconfigured (disabled)");

        uint256 amount = 100e18;
        probe.probeFastOutbound(SELECTOR, amount);

        (RateLimiter.TokenBucket memory defAfter,) = probe.getCurrentRateLimiterState(SELECTOR, false);
        (RateLimiter.TokenBucket memory fastAfter,) = probe.getCurrentRateLimiterState(SELECTOR, true);
        // Same block => no refill: the fast-finality consume fell back to the DEFAULT bucket.
        assertEq(defBefore.tokens - defAfter.tokens, amount, "default bucket consumed by the fast transfer");
        assertFalse(fastAfter.isEnabled, "fast bucket stayed unconfigured (no bypass)");
        assertEq(fastAfter.tokens, 0, "unconfigured fast bucket never held tokens");
    }
}
