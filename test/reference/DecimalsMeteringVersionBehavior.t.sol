// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @dev `RateLimitConfigArgs` mirrors `TokenPool.RateLimitConfigArgs` (v2.0 setter arg). The v1.5.x and
///      v2.0 `ReleaseOrMintInV1` structs share an identical ABI layout (the v1.5.x `amount` field is the
///      v2.0 `sourceDenominatedAmount` slot), so the imported v2.0 `Pool.ReleaseOrMintInV1` encodes
///      correctly for every version under test. releaseOrMint return types are omitted deliberately: the
///      selector depends only on argument types and every call here is expected to revert at the inbound
///      rate-limit consume, so no return value is ever decoded.
struct RateLimitConfigArgs {
    uint64 remoteChainSelector;
    bool fastFinality;
    RateLimiter.Config outboundRateLimiterConfig;
    RateLimiter.Config inboundRateLimiterConfig;
}

interface IMeteringPool {
    function typeAndVersion() external view returns (string memory);
    function setChainRateLimiterConfig(
        uint64 remoteChainSelector,
        RateLimiter.Config calldata outbound,
        RateLimiter.Config calldata inbound
    ) external;
    function setRateLimitConfig(RateLimitConfigArgs[] calldata args) external;
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn) external;
}

interface IRouterOffRamp {
    function isOffRamp(uint64 sourceChainSelector, address offRamp) external view returns (bool);
}

/// @title DecimalsMeteringVersionBehavior
/// @notice Version-behavior fixtures backing the docs/reference/pool-behavior-matrix.md "inbound
///         rate-limit metered on" row. It drives `releaseOrMint` on the REAL deployed bytecode of each
///         pool version over a Sepolia fork, with a decimals MISMATCH (local token = 18 decimals, remote
///         declared = 6 decimals, so localAmount = sourceAmount * 1e12). The inbound limiter capacity is
///         chosen so the metered amount is revealed by the `TokenMaxCapacityExceeded(capacity, requested,
///         token)` revert: `requested` is exactly the amount the pool metered.
///
/// Source anchors (chainlink-ccip / vendored old releases):
///   - v1.5.0 TokenPool.sol: `_validateReleaseOrMint` consumes inbound on the RAW `releaseOrMintIn.amount`
///     (no `_calculateLocalAmount` exists - mixed decimals unsupported; meters source 1:1).
///   - v1.5.1 TokenPool.sol: consumes inbound on the UN-RESCALED `releaseOrMintIn.amount` (rescale via
///     `_calculateLocalAmount` exists but is applied only to the mint, not to the metering).
///   - v1.6.1 / v2.0 TokenPool.sol: `releaseOrMint` computes `localAmount = _calculateLocalAmount(...)`
///     FIRST, then consumes inbound on `localAmount` (meters the rescaled local amount).
///
/// The consume reverts BEFORE any mint, so no fork state past the limiter is mutated. `_onlyOffRamp` is
/// satisfied by mocking `router.isOffRamp(...) -> true`; the live RMN (not cursed for these lanes) and the
/// real remote-pool wiring are used unmodified.
contract DecimalsMeteringVersionBehavior is BaseForkTest {
    address internal constant OWNER = 0x9d087fC03ae39b088326b67fA3C788236645b717;
    address internal constant ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; // shared by all four pools

    address internal constant V150 = 0x12308B9b64CA40BD8d15daB6679876123Afda026; // BurnMintTokenPool 1.5.0
    address internal constant V151 = 0x7B076F553BCa97266E23A1B301C94398C531e952; // BurnMintTokenPool 1.5.1
    address internal constant V161 = 0x898ABAA106686F91f783166Abe336E7C7423Ca89; // BurnMintTokenPool 1.6.1
    address internal constant V200 = 0x3C5Cafc14751b12CE7ad1Af669cF81586CD5061E; // BurnMintTokenPool 2.0.0

    uint64 internal constant BASE_SEPOLIA = 8236463271206331221; // V150 / V151 lane
    uint64 internal constant FUJI = 14767482510784806043; // V161 / V200 lane

    // Local tokens (both 18 decimals, read live).
    address internal constant TOKEN_15X = 0x10399C551d63F596B9b980E089d7ad5B616Fc152; // V150 / V151
    address internal constant TOKEN_16X = 0x65901d3177F69CFA5b341C95D3943e72FFb2716A; // V161 / V200

    // Real remote pool addresses per lane (getRemotePool[s], read live). sourcePoolAddress must match.
    address internal constant REMOTE_15X = 0x1111111111111111111111111111111111111111; // V150 / V151 (BASE)
    address internal constant REMOTE_161 = 0xBBD9C0518fF156d9a198e8968336162c45082727; // V161 (FUJI)
    address internal constant REMOTE_200 = 0x506f9D311A211e44553AD0F921AA4988fABBc602; // V200 (FUJI)

    address internal constant CALLER = address(0xB0B); // pranked as the (mocked) off-ramp.

    // Decimals mismatch: local 18, remote 6 → localAmount = sourceAmount * 1e12.
    uint8 internal constant REMOTE_DECIMALS = 6;
    uint256 internal constant SOURCE_AMOUNT = 1_000; // in remote (6-dec) units.
    uint256 internal constant LOCAL_AMOUNT = 1_000 * 1e12; // rescaled to 18-dec local units = 1e15.

    function setUp() public override {
        _createSepoliaFork();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _cfg(uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate});
    }

    function _setInboundV1(address pool, uint64 sel, uint128 capacity, uint128 rate) internal {
        // v1.5.x requires rate < capacity && rate != 0; v1.6.x requires rate <= capacity. rate = 1 fits both.
        vm.prank(OWNER);
        IMeteringPool(pool).setChainRateLimiterConfig(sel, _cfg(capacity, rate), _cfg(capacity, rate));
    }

    function _setInboundV2(address pool, uint64 sel, uint128 capacity, uint128 rate) internal {
        RateLimitConfigArgs[] memory args = new RateLimitConfigArgs[](1);
        args[0] = RateLimitConfigArgs({
            remoteChainSelector: sel,
            fastFinality: false,
            outboundRateLimiterConfig: _cfg(capacity, rate),
            inboundRateLimiterConfig: _cfg(capacity, rate)
        });
        vm.prank(OWNER);
        IMeteringPool(pool).setRateLimitConfig(args);
    }

    function _mockOffRamp(uint64 sel) internal {
        vm.mockCall(ROUTER, abi.encodeWithSelector(IRouterOffRamp.isOffRamp.selector, sel, CALLER), abi.encode(true));
    }

    function _release(address pool, uint64 sel, address token, address remotePool) internal {
        vm.prank(CALLER);
        IMeteringPool(pool)
            .releaseOrMint(
                Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(OWNER),
                remoteChainSelector: sel,
                receiver: OWNER,
                sourceDenominatedAmount: SOURCE_AMOUNT,
                localToken: token,
                sourcePoolAddress: abi.encode(remotePool),
                sourcePoolData: abi.encode(uint256(REMOTE_DECIMALS)),
                offchainTokenData: ""
            })
            );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Claim 4: which amount the inbound limiter meters, by version.
    // The revert `TokenMaxCapacityExceeded(capacity, requested, token)` exposes `requested`.
    // ═════════════════════════════════════════════════════════════════════════

    /// v1.5.0: no rescale exists - meters the RAW source amount 1:1. Capacity below the source amount, so
    /// the metered value shows up as `requested == SOURCE_AMOUNT` (NOT the 1e12-scaled local amount).
    function test_claim4_v150_meters_raw_source_amount() public {
        _mockOffRamp(BASE_SEPOLIA);
        _setInboundV1(V150, BASE_SEPOLIA, uint128(SOURCE_AMOUNT - 1), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RateLimiter.TokenMaxCapacityExceeded.selector, SOURCE_AMOUNT - 1, SOURCE_AMOUNT, TOKEN_15X
            )
        );
        _release(V150, BASE_SEPOLIA, TOKEN_15X, REMOTE_15X);
    }

    /// v1.5.1: meters the UN-RESCALED source amount (rescale exists but only for the mint). Same oracle:
    /// `requested == SOURCE_AMOUNT`, proving the metering did NOT rescale first.
    function test_claim4_v151_meters_unrescaled_source_amount() public {
        _mockOffRamp(BASE_SEPOLIA);
        _setInboundV1(V151, BASE_SEPOLIA, uint128(SOURCE_AMOUNT - 1), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RateLimiter.TokenMaxCapacityExceeded.selector, SOURCE_AMOUNT - 1, SOURCE_AMOUNT, TOKEN_15X
            )
        );
        _release(V151, BASE_SEPOLIA, TOKEN_15X, REMOTE_15X);
    }

    /// v1.6.1: rescales first, meters the LOCAL amount. Capacity sits ABOVE the source amount but BELOW
    /// the rescaled local amount, so the revert exposes `requested == LOCAL_AMOUNT` (source metering would
    /// NOT have reverted at this capacity).
    function test_claim4_v161_meters_rescaled_local_amount() public {
        _mockOffRamp(FUJI);
        _setInboundV1(V161, FUJI, 1e9, 1); // SOURCE_AMOUNT(1e3) < 1e9 < LOCAL_AMOUNT(1e15)
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(1e9), LOCAL_AMOUNT, TOKEN_16X)
        );
        _release(V161, FUJI, TOKEN_16X, REMOTE_161);
    }

    /// v2.0: rescales first, meters the LOCAL amount (standard inbound bucket). Same oracle as v1.6.1.
    function test_claim4_v200_meters_rescaled_local_amount() public {
        _mockOffRamp(FUJI);
        _setInboundV2(V200, FUJI, 1e9, 1); // SOURCE_AMOUNT(1e3) < 1e9 < LOCAL_AMOUNT(1e15)
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, uint256(1e9), LOCAL_AMOUNT, TOKEN_16X)
        );
        _release(V200, FUJI, TOKEN_16X, REMOTE_200);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Sanity: the live pools are the versions we think they are.
    // ═════════════════════════════════════════════════════════════════════════

    function test_pool_versions_are_live_and_expected() public view {
        assertEq(IMeteringPool(V150).typeAndVersion(), "BurnMintTokenPool 1.5.0");
        assertEq(IMeteringPool(V151).typeAndVersion(), "BurnMintTokenPool 1.5.1");
        assertEq(IMeteringPool(V161).typeAndVersion(), "BurnMintTokenPool 1.6.1");
        assertEq(IMeteringPool(V200).typeAndVersion(), "BurnMintTokenPool 2.0.0");
    }
}
