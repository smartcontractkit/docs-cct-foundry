// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @dev Minimal ABI surface of the live TokenPool versions under test. `RateLimiter.Config` and
///      `RateLimiter.TokenBucket` are imported from the pinned @chainlink/contracts-ccip@2.0.0 and match
///      the field layout the older pools also use (isEnabled/capacity/rate). `RateLimitConfigArgs`
///      mirrors `TokenPool.RateLimitConfigArgs` (the v2.0 setter arg). lockOrBurn return types are
///      omitted deliberately: the selector depends only on argument types, and every lockOrBurn call in
///      this suite is expected to revert (either the rate-limit error, or the ERC20 burn-balance error
///      that proves the limiter ALLOWED the call), so no return value is ever decoded.
struct RateLimitConfigArgs {
    uint64 remoteChainSelector;
    bool fastFinality;
    RateLimiter.Config outboundRateLimiterConfig;
    RateLimiter.Config inboundRateLimiterConfig;
}

interface IVersionedPool {
    function typeAndVersion() external view returns (string memory);
    function owner() external view returns (address);
    // v1.5.0 / v1.5.1 / v1.6.1 rate-limit setter.
    function setChainRateLimiterConfig(
        uint64 remoteChainSelector,
        RateLimiter.Config calldata outbound,
        RateLimiter.Config calldata inbound
    ) external;
    // v2.0.0 rate-limit setter (standard + fast-finality axis).
    function setRateLimitConfig(RateLimitConfigArgs[] calldata args) external;
    function getCurrentRateLimiterState(uint64 remoteChainSelector, bool fastFinality)
        external
        view
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound);
    function setAllowedFinalityConfig(bytes4 allowedFinality) external;
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn) external;
    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn,
        bytes4 requestedFinalityConfig,
        bytes calldata tokenArgs
    ) external;
}

/// @title RateLimiterVersionBehavior
/// @notice Version-behavior fixtures backing docs/reference/pool-behavior-matrix.md rows for the
///         RateLimiter config-validation deltas, the PAUSE mechanics, the enabled-vs-disabled 0/0
///         footgun, and the v2.0 fast-finality (FTF) bucket trap + fallback.
///
/// This is a Sepolia fork test that exercises the REAL deployed bytecode of all four pool versions
/// (1.5.0, 1.5.1, 1.6.1, 2.0.0), not a mock. `vm.prank(owner)` / `vm.prank(onRamp)` mutate only the
/// in-memory fork, never mainnet. Source anchors (chainlink-ccip):
///   - RateLimiter.sol `_setTokenBucketConfig` (v2.0 tip): enabled reverts only when `rate > capacity`;
///     disabled must be 0/0 else `DisabledNonZeroRateLimit`.
///   - Vendored v1.5.0/v1.5.1 RateLimiter `_validateTokenBucketConfig`: enabled reverts when
///     `rate >= capacity || rate == 0` (`InvalidRateLimitRate`).
///   - RateLimiter.sol `_consume`: reverts `TokenMaxCapacityExceeded` when `capacity < requestTokens`;
///     no-op when `!isEnabled || requestTokens == 0`.
///   - TokenPool.sol `_consumeFastFinalityOutboundRateLimit`: falls back to the standard bucket when the
///     FTF bucket is disabled.
contract RateLimiterVersionBehavior is BaseForkTest {
    // Live Sepolia pools (a single owner EOA owns all four).
    address internal constant OWNER = 0x9d087fC03ae39b088326b67fA3C788236645b717;
    address internal constant V150 = 0x12308B9b64CA40BD8d15daB6679876123Afda026; // BurnMintTokenPool 1.5.0
    address internal constant V151 = 0x7B076F553BCa97266E23A1B301C94398C531e952; // BurnMintTokenPool 1.5.1
    address internal constant V161 = 0x898ABAA106686F91f783166Abe336E7C7423Ca89; // BurnMintTokenPool 1.6.1
    address internal constant V200 = 0x3C5Cafc14751b12CE7ad1Af669cF81586CD5061E; // BurnMintTokenPool 2.0.0

    // Lanes actually supported by each pool (getSupportedChains, read live).
    uint64 internal constant BASE_SEPOLIA = 8236463271206331221; // supported by V150 / V151
    uint64 internal constant FUJI = 14767482510784806043; // supported by V161 / V200

    // V200 runtime plumbing: token + the v1.x GA Router onRamp for the Fuji lane (Router.getOnRamp(FUJI)).
    address internal constant V200_TOKEN = 0x65901d3177F69CFA5b341C95D3943e72FFb2716A;
    address internal constant V200_ONRAMP = 0x12492154714fBD28F28219f6fc4315d19de1025B;

    // MG161A is an old-OZ BurnMintERC20: burning past balance reverts with this string. Seeing it (rather
    // than TokenMaxCapacityExceeded) is the oracle that the rate limiter ALLOWED the transfer amount.
    string internal constant BURN_BALANCE = "ERC20: burn amount exceeds balance";

    function setUp() public override {
        // Only the Sepolia fork is needed; skip the token/pool deploy fixtures of BaseForkTest.setUp.
        _createSepoliaFork();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _cfg(bool enabled, uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: enabled, capacity: capacity, rate: rate});
    }

    /// @dev Set both directions of the STANDARD bucket on a v1.5/1.6 pool as the owner.
    function _setV1(address pool, uint64 sel, RateLimiter.Config memory c) internal {
        vm.prank(OWNER);
        IVersionedPool(pool).setChainRateLimiterConfig(sel, c, c);
    }

    /// @dev Set both directions of one bucket axis on the v2.0 pool as the owner.
    function _setV2(address pool, uint64 sel, bool fastFinality, RateLimiter.Config memory c) internal {
        RateLimitConfigArgs[] memory args = new RateLimitConfigArgs[](1);
        args[0] = RateLimitConfigArgs({
            remoteChainSelector: sel,
            fastFinality: fastFinality,
            outboundRateLimiterConfig: c,
            inboundRateLimiterConfig: c
        });
        vm.prank(OWNER);
        IVersionedPool(pool).setRateLimitConfig(args);
    }

    /// @dev A minimal standard (wait-for-finality) lockOrBurn of `amount`, pranked as the onRamp.
    function _lockOrBurnStd(uint256 amount) internal {
        vm.prank(V200_ONRAMP);
        IVersionedPool(V200)
            .lockOrBurn(
                Pool.LockOrBurnInV1({
                receiver: abi.encode(OWNER),
                remoteChainSelector: FUJI,
                originalSender: OWNER,
                amount: amount,
                localToken: V200_TOKEN
            })
            );
    }

    /// @dev A fast-finality lockOrBurn of `amount`, pranked as the onRamp. `finality` must be allowed by
    ///      the pool's allowedFinalityConfig.
    function _lockOrBurnFtf(uint256 amount, bytes4 finality) internal {
        vm.prank(V200_ONRAMP);
        IVersionedPool(V200)
            .lockOrBurn(
                Pool.LockOrBurnInV1({
                receiver: abi.encode(OWNER),
                remoteChainSelector: FUJI,
                originalSender: OWNER,
                amount: amount,
                localToken: V200_TOKEN
            }),
                finality,
                ""
            );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Claim 1 + Claim 2: config-validation boundary by version.
    // v1.5.x: enabled reverts when `rate >= capacity || rate == 0`.
    // v1.6+/v2.0: enabled reverts ONLY when `rate > capacity` (rate == 0 allowed).
    // ═════════════════════════════════════════════════════════════════════════

    function test_claim1_2_v150_rejects_rate_ge_capacity_and_rate_zero() public {
        // enabled 1/1 → rate >= capacity → revert (Claim 2: capacity=1,rate=1 REVERTS on v1.5.x).
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 1, 1)));
        _setV1(V150, BASE_SEPOLIA, _cfg(true, 1, 1));
        // enabled 0/0 → rate == 0 → revert (Claim 3: enabled-0/0 pause IMPOSSIBLE on v1.5.x).
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 0, 0)));
        _setV1(V150, BASE_SEPOLIA, _cfg(true, 0, 0));
        // enabled 5/0 → rate == 0 → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 5, 0)));
        _setV1(V150, BASE_SEPOLIA, _cfg(true, 5, 0));
        // enabled 2/1 → capacity > rate, rate != 0 → accepted (the v1.5.x near-pause).
        _setV1(V150, BASE_SEPOLIA, _cfg(true, 2, 1));
        // disabled 0/0 → accepted (removes the limit).
        _setV1(V150, BASE_SEPOLIA, _cfg(false, 0, 0));
        // disabled 5/5 → nonzero on a disabled bucket → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.DisabledNonZeroRateLimit.selector, _cfg(false, 5, 5)));
        _setV1(V150, BASE_SEPOLIA, _cfg(false, 5, 5));
    }

    function test_claim1_2_v151_rejects_rate_ge_capacity_and_rate_zero() public {
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 1, 1)));
        _setV1(V151, BASE_SEPOLIA, _cfg(true, 1, 1));
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 0, 0)));
        _setV1(V151, BASE_SEPOLIA, _cfg(true, 0, 0));
        _setV1(V151, BASE_SEPOLIA, _cfg(true, 2, 1)); // near-pause accepted.
    }

    function test_claim1_2_v161_rejects_only_rate_gt_capacity() public {
        // enabled 1/1 → valid on v1.6+ (rate not > capacity) - Claim 2: capacity=1,rate=1 VALID.
        _setV1(V161, FUJI, _cfg(true, 1, 1));
        // enabled 0/0 → valid on v1.6+ (the clean pause) - Claim 3: SETTABLE on v1.6+.
        _setV1(V161, FUJI, _cfg(true, 0, 0));
        // enabled 5/6 → rate > capacity → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 5, 6)));
        _setV1(V161, FUJI, _cfg(true, 5, 6));
        // disabled 5/5 → nonzero on disabled → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.DisabledNonZeroRateLimit.selector, _cfg(false, 5, 5)));
        _setV1(V161, FUJI, _cfg(false, 5, 5));
    }

    function test_claim1_2_v200_rejects_only_rate_gt_capacity() public {
        // enabled 1/1 accepted on v2 (standard + FTF).
        _setV2(V200, FUJI, false, _cfg(true, 1, 1));
        _setV2(V200, FUJI, true, _cfg(true, 1, 1));
        // enabled 0/0 accepted on v2 (standard + FTF) - the clean pause is SETTABLE.
        _setV2(V200, FUJI, false, _cfg(true, 0, 0));
        _setV2(V200, FUJI, true, _cfg(true, 0, 0));
        // rate > capacity → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRateLimitRate.selector, _cfg(true, 5, 6)));
        _setV2(V200, FUJI, false, _cfg(true, 5, 6));
        // disabled nonzero → revert.
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.DisabledNonZeroRateLimit.selector, _cfg(false, 5, 5)));
        _setV2(V200, FUJI, false, _cfg(false, 5, 5));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Claim 3: enabled 0/0 is a true zero-throughput pause; enabled-vs-disabled 0/0 footgun.
    // ═════════════════════════════════════════════════════════════════════════

    function test_claim3_v200_enabled_0_0_pauses_standard_transfer() public {
        _setV2(V200, FUJI, false, _cfg(true, 0, 0)); // enabled 0/0 pause.
        (RateLimiter.TokenBucket memory outb,) = IVersionedPool(V200).getCurrentRateLimiterState(FUJI, false);
        assertTrue(outb.isEnabled, "paused bucket must stay enabled");
        assertEq(outb.capacity, 0, "paused capacity must be 0");
        assertEq(outb.rate, 0, "paused rate must be 0");
        // Any nonzero transfer is now blocked at the source pool: capacity(0) < requestTokens(1).
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(0), uint256(1), V200_TOKEN)
        );
        _lockOrBurnStd(1);
    }

    function test_claim3_v200_disabled_0_0_is_unlimited_footgun() public {
        _setV2(V200, FUJI, false, _cfg(false, 0, 0)); // disabled 0/0 = REMOVE the limit.
        (RateLimiter.TokenBucket memory outb,) = IVersionedPool(V200).getCurrentRateLimiterState(FUJI, false);
        assertFalse(outb.isEnabled, "removed bucket must be disabled");
        // A huge transfer is ALLOWED by the limiter (no cap) - proven by reaching the burn step.
        vm.expectRevert(bytes(BURN_BALANCE));
        _lockOrBurnStd(1e30);
    }

    function test_claim3_v200_within_limit_transfer_is_allowed() public {
        // A generous enabled bucket lets a small amount pass the limiter and reach the burn.
        _setV2(V200, FUJI, false, _cfg(true, 1e24, 1e21));
        vm.expectRevert(bytes(BURN_BALANCE));
        _lockOrBurnStd(1);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Claim 5: v2.0 fast-finality is a SEPARATE limiter that FALLS BACK to the standard bucket when the
    // FTF bucket is disabled (TokenPool._consumeFastFinalityOutboundRateLimit).
    // ═════════════════════════════════════════════════════════════════════════

    // Allow a block-depth FTF request: allowedBlockDepth = 1, request depth = 100 (>= allowed).
    bytes4 internal constant ALLOWED_FINALITY = bytes4(uint32(1));
    bytes4 internal constant FTF_REQUEST = bytes4(uint32(100));

    function _allowFtf() internal {
        vm.prank(OWNER);
        IVersionedPool(V200).setAllowedFinalityConfig(ALLOWED_FINALITY);
    }

    function test_claim5_v200_ftf_trap_standardPauseOnly_leaves_ftf_flowing() public {
        _allowFtf();
        _setV2(V200, FUJI, false, _cfg(true, 0, 0)); // PAUSE standard only.
        _setV2(V200, FUJI, true, _cfg(true, 1e24, 1e21)); // FTF bucket ENABLED with headroom.

        // Standard transfer: BLOCKED by the standard pause.
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(0), uint256(1), V200_TOKEN)
        );
        _lockOrBurnStd(1);

        // Fast-finality transfer: ALLOWED (uses the separate, un-paused FTF bucket) - the trap.
        vm.expectRevert(bytes(BURN_BALANCE));
        _lockOrBurnFtf(1, FTF_REQUEST);
    }

    function test_claim5_v200_ftf_fallback_disabledFtf_is_covered_by_standard_pause() public {
        _allowFtf();
        _setV2(V200, FUJI, false, _cfg(true, 0, 0)); // PAUSE standard.
        _setV2(V200, FUJI, true, _cfg(false, 0, 0)); // FTF bucket DISABLED (the default).

        // An FTF transfer falls back to the standard bucket and is BLOCKED by the standard pause.
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(0), uint256(1), V200_TOKEN)
        );
        _lockOrBurnFtf(1, FTF_REQUEST);
    }

    function test_claim5_v200_full_pause_blocks_both_standard_and_ftf() public {
        _allowFtf();
        _setV2(V200, FUJI, false, _cfg(true, 0, 0)); // PAUSE standard.
        _setV2(V200, FUJI, true, _cfg(true, 0, 0)); // PAUSE fast-finality too.

        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(0), uint256(1), V200_TOKEN)
        );
        _lockOrBurnStd(1);
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(0), uint256(1), V200_TOKEN)
        );
        _lockOrBurnFtf(1, FTF_REQUEST);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Sanity: the live pools are the versions we think they are.
    // ═════════════════════════════════════════════════════════════════════════

    function test_pool_versions_are_live_and_expected() public view {
        assertEq(IVersionedPool(V150).typeAndVersion(), "BurnMintTokenPool 1.5.0");
        assertEq(IVersionedPool(V151).typeAndVersion(), "BurnMintTokenPool 1.5.1");
        assertEq(IVersionedPool(V161).typeAndVersion(), "BurnMintTokenPool 1.6.1");
        assertEq(IVersionedPool(V200).typeAndVersion(), "BurnMintTokenPool 2.0.0");
        assertEq(IVersionedPool(V200).owner(), OWNER);
    }
}
