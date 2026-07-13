// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {CctActions, ILockReleaseV1Liquidity} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {PoolVersion} from "../../script/utils/PoolVersion.s.sol";
import {LiquidityBase} from "../../script/configure/liquidity/LiquidityBase.s.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks — the minimal on-chain surface each fence branch inspects
// ─────────────────────────────────────────────────────────────────────────────

/// @dev A v1.x LockRelease pool: the rebalancer/liquidity surface plus getToken. `typeAndVersion`
///      reports a cataloged v1.x version, so the fence resolves it and passes.
contract MockV1LockReleasePool {
    string public typeAndVersion;
    address private s_rebalancer;
    IERC20 private immutable I_TOKEN;

    constructor(string memory t, IERC20 token, address rebalancer) {
        typeAndVersion = t;
        I_TOKEN = token;
        s_rebalancer = rebalancer;
    }

    function getToken() external view returns (IERC20) {
        return I_TOKEN;
    }

    function getRebalancer() external view returns (address) {
        return s_rebalancer;
    }

    function setRebalancer(address rebalancer) external {
        s_rebalancer = rebalancer;
    }

    // Minimal state-mutating bodies: the fence/precondition unit tests never call these (they assert on
    // the builder calldata and the resolver), so tracking a counter keeps them non-view without pulling
    // in a full ERC20 transfer (which the linter would flag as an unchecked-return call).
    uint256 public liquidity;

    function provideLiquidity(uint256 amount) external {
        liquidity += amount;
    }

    function withdrawLiquidity(uint256 amount) external {
        liquidity -= amount;
    }
}

/// @dev A 2.0.0 LockRelease pool: no rebalancer surface, only the lock box getter.
contract MockV2LockReleasePool {
    address private s_lockBox;

    constructor(address lockBox) {
        s_lockBox = lockBox;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "LockReleaseTokenPool 2.0.0";
    }

    function getLockBox() external view returns (address) {
        return s_lockBox;
    }
}

/// @dev A BurnMint pool: a cataloged version, but the WRONG type for liquidity management.
contract MockBurnMintPool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.6.1";
    }
}

/// @dev A LockRelease pool reporting an UNCATALOGED (pre-1.5.0) version: resolve refuses it.
contract MockUncatalogedLockReleasePool {
    function typeAndVersion() external pure returns (string memory) {
        return "LockReleaseTokenPool 1.4.0";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Harnesses — external-call seams so try/catch and expectRevert apply to the library call
// ─────────────────────────────────────────────────────────────────────────────

contract LiquidityFenceShim {
    function requireLockReleaseLiquidity(address pool)
        external
        view
        returns (PoolVersions.Version version, string memory full)
    {
        return PoolVersion.requireLockReleaseLiquidity(pool);
    }
}

/// @dev Exposes LiquidityBase's precondition checks + their pure message builders for byte-exact pinning.
contract LiquidityBaseHarness is LiquidityBase {
    function requireRebalancer(address pool, address broadcasterAddr, string memory op) external view {
        _requireRebalancer(pool, broadcasterAddr, op);
    }

    function requireSufficientLiquidity(address pool, uint256 balance, uint256 amount) external pure {
        _requireSufficientLiquidity(pool, balance, amount);
    }

    function rebalancerMismatchMessage(string memory op, address rebalancer, address broadcasterAddr)
        external
        pure
        returns (string memory)
    {
        return _rebalancerMismatchMessage(op, rebalancer, broadcasterAddr);
    }

    function insufficientLiquidityMessage(address pool, uint256 balance, uint256 amount)
        external
        pure
        returns (string memory)
    {
        return _insufficientLiquidityMessage(pool, balance, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Proofs for the v1.x LockRelease liquidity surface:
///         - the two-dimensional fence (type AND version): v1.x LockRelease passes; a 2.0.0 LockRelease
///           gets the lock-box-pointer refusal (not the generic unsupported-operation error); a BurnMint
///           gets the wrong-type refusal; an uncataloged/pre-1.5.0 pool is refused by the resolver;
///         - the CctActions builders' calldata (setRebalancer / provideLiquidity / withdrawLiquidity) and
///           the approve-then-provide batch the ProvideLiquidity script broadcasts;
///         - the two script-level precondition messages (rebalancer mismatch, insufficient liquidity),
///           pinned byte-exact against their builders.
contract LockReleaseLiquidityTest is Test {
    address internal constant POOL = address(0x3333333333333333333333333333333333333333);
    address internal constant TOKEN = address(0x2222222222222222222222222222222222222222);
    address internal constant REBALANCER = address(0x4444444444444444444444444444444444444444);

    LiquidityFenceShim internal fence;
    LiquidityBaseHarness internal harness;

    function setUp() public {
        fence = new LiquidityFenceShim();
        harness = new LiquidityBaseHarness();
    }

    // ── Fence: the passing case (v1.x LockRelease) ──────────────────────────────

    function test_Fence_V1LockRelease_Passes() public {
        address pool = address(new MockV1LockReleasePool("LockReleaseTokenPool 1.6.1", IERC20(TOKEN), REBALANCER));
        (PoolVersions.Version v, string memory full) = fence.requireLockReleaseLiquidity(pool);
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_6_1), "resolves to 1.6.1");
        assertEq(full, "LockReleaseTokenPool 1.6.1", "true on-chain string returned");
    }

    function test_Fence_V150LockRelease_Passes() public {
        // The APPROVED-flow floor: 1.5.0 is a cataloged v1.x version and carries the rebalancer surface.
        address pool = address(new MockV1LockReleasePool("LockReleaseTokenPool 1.5.0", IERC20(TOKEN), REBALANCER));
        (PoolVersions.Version v,) = fence.requireLockReleaseLiquidity(pool);
        assertEq(uint256(v), uint256(PoolVersions.Version.V1_5_0), "resolves to 1.5.0");
    }

    // ── Fence: the two refusal branches, byte-exact ─────────────────────────────

    function test_Fence_V2LockRelease_LockBoxPointerRefusal() public {
        address pool = address(new MockV2LockReleasePool(address(0xB0)));
        string memory reason = _catchFence(pool);
        _assertContains(reason, "LiquidityManagedByLockBox");
        _assertContains(
            reason,
            "on 2.0.0 LockRelease pools, liquidity is managed via the external lock box"
            " - use operations/DepositToLockBox.s.sol / WithdrawFromLockBox.s.sol"
        );
        // NOT the generic unsupported-operation error.
        assertFalse(_contains(reason, "UnsupportedPoolOperation"), "must be the helpful pointer, not the generic error");
    }

    function test_Fence_BurnMint_WrongTypeRefusal() public {
        address pool = address(new MockBurnMintPool());
        string memory reason = _catchFence(pool);
        _assertContains(reason, "UnsupportedPoolTypeForLiquidity");
        _assertContains(reason, "liquidity management is only on LockRelease pools; this is a BurnMintTokenPool");
        assertFalse(_contains(reason, "UnsupportedPoolOperation"), "wrong-type must not be the generic error");
    }

    function test_Fence_Uncataloged_Refused() public {
        address pool = address(new MockUncatalogedLockReleasePool());
        string memory reason = _catchFence(pool);
        // The strict resolver refuses a pre-1.5.0 (uncataloged) version before the liquidity fence runs.
        _assertContains(reason, "UnsupportedPoolVersion");
        _assertContains(reason, "1.4.0");
    }

    // ── Builder calldata ────────────────────────────────────────────────────────

    function test_SetRebalancer_BuildsTheCall() public pure {
        CctActions.Call[] memory calls = CctActions.setRebalancer(POOL, REBALANCER);
        assertEq(calls.length, 1, "one call");
        assertEq(calls[0].target, POOL, "target is the pool");
        assertEq(calls[0].value, 0, "value 0");
        assertEq(
            calls[0].data,
            abi.encodeCall(ILockReleaseV1Liquidity.setRebalancer, (REBALANCER)),
            "setRebalancer(address) calldata"
        );
    }

    function test_ProvideLiquidity_ApprovesThenProvides() public pure {
        uint256 amount = 1_000e18;
        // The exact batch ProvideLiquidity.s.sol broadcasts: approve(pool, amount) then provideLiquidity.
        CctActions.Call[] memory calls =
            CctActions.concat(CctActions.approve(TOKEN, POOL, amount), CctActions.provideLiquidity(POOL, amount));
        assertEq(calls.length, 2, "approve + provide");
        assertEq(calls[0].target, TOKEN, "approve targets the token");
        assertEq(calls[0].data, abi.encodeCall(IERC20.approve, (POOL, amount)), "approve(pool, amount) calldata");
        assertEq(calls[1].target, POOL, "provide targets the pool");
        assertEq(
            calls[1].data,
            abi.encodeCall(ILockReleaseV1Liquidity.provideLiquidity, (amount)),
            "provideLiquidity(uint256) calldata"
        );
    }

    function test_WithdrawLiquidity_BuildsTheCall() public pure {
        uint256 amount = 250e18;
        CctActions.Call[] memory calls = CctActions.withdrawLiquidity(POOL, amount);
        assertEq(calls.length, 1, "one call");
        assertEq(calls[0].target, POOL, "target is the pool");
        assertEq(
            calls[0].data,
            abi.encodeCall(ILockReleaseV1Liquidity.withdrawLiquidity, (amount)),
            "withdrawLiquidity(uint256) calldata"
        );
    }

    // ── Script-level precondition messages (byte-exact vs their builders) ───────

    function test_RequireRebalancer_RefusesMismatchByName() public {
        address pool = address(new MockV1LockReleasePool("LockReleaseTokenPool 1.6.1", IERC20(TOKEN), REBALANCER));
        address broadcasterAddr = address(0xDEAD);
        string memory expected = harness.rebalancerMismatchMessage("provideLiquidity", REBALANCER, broadcasterAddr);
        _assertContains(expected, "NotRebalancer: provideLiquidity can only be called by the pool's rebalancer");
        vm.expectRevert(bytes(expected));
        harness.requireRebalancer(pool, broadcasterAddr, "provideLiquidity");
    }

    function test_RequireRebalancer_PassesWhenBroadcasterIsRebalancer() public {
        address pool = address(new MockV1LockReleasePool("LockReleaseTokenPool 1.6.1", IERC20(TOKEN), REBALANCER));
        // No revert.
        harness.requireRebalancer(pool, REBALANCER, "provideLiquidity");
    }

    function test_RequireSufficientLiquidity_RefusesShortfallByName() public {
        string memory expected = harness.insufficientLiquidityMessage(POOL, 5e18, 10e18);
        _assertContains(expected, "InsufficientLiquidity: pool ");
        _assertContains(expected, "the v1 pool reverts InsufficientLiquidity when its balance is below the amount");
        vm.expectRevert(bytes(expected));
        harness.requireSufficientLiquidity(POOL, 5e18, 10e18);
    }

    function test_RequireSufficientLiquidity_PassesWhenEnough() public view {
        harness.requireSufficientLiquidity(POOL, 10e18, 10e18);
    }

    // ── op-range spot checks (the count-guard table proves the full grid) ───────

    function test_OpRanges_LiquidityOpsAreV1xOnly() public pure {
        PoolVersions.Op[4] memory ops = [
            PoolVersions.Op.GET_REBALANCER,
            PoolVersions.Op.SET_REBALANCER,
            PoolVersions.Op.PROVIDE_LIQUIDITY,
            PoolVersions.Op.WITHDRAW_LIQUIDITY
        ];
        for (uint256 i = 0; i < ops.length; i++) {
            assertTrue(PoolVersions.isSupported(ops[i], PoolVersions.Version.V1_5_0), "supported on 1.5.0");
            assertTrue(PoolVersions.isSupported(ops[i], PoolVersions.Version.V1_5_1), "supported on 1.5.1");
            assertTrue(PoolVersions.isSupported(ops[i], PoolVersions.Version.V1_6_1), "supported on 1.6.1");
            assertFalse(PoolVersions.isSupported(ops[i], PoolVersions.Version.V2_0_0), "removed in 2.0.0");
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _catchFence(address pool) internal view returns (string memory reason) {
        try fence.requireLockReleaseLiquidity(pool) {
            revert("fence unexpectedly passed");
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
}
