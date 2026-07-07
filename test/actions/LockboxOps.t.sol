// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {DeployERC20LockBox} from "../../script/deploy/DeployERC20LockBox.s.sol";
import {DeployLockReleaseTokenPool} from "../../script/deploy/DeployLockReleaseTokenPool.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice LockRelease + ERC20LockBox fork fixture for the PR 1.2 rollout. The fixture is built with the
/// repo's OWN deploy scripts in the README order — lockbox first, then the LockReleaseTokenPool, then the
/// pool is authorized on the lockbox via the authorized-callers action. It proves the invariant that a
/// lockbox deposit/withdraw succeeds ONLY after the caller is authorized, and exercises both README
/// LockRelease topologies (single-lock-chain and lock-and-lock) at the shared local lock/release layer.
contract LockboxOpsForkTest is BaseForkTest {
    // Selectors for the two README LockRelease patterns (remote-lane wiring differs; the LOCAL lock/release
    // mechanics through the lockbox are identical, which is exactly what this fixture exercises).
    uint64 internal constant SINGLE_LOCK_CHAIN_SELECTOR = 8236463271206331221; // Mantle Sepolia (remote burns/mints)
    uint64 internal constant LOCK_AND_LOCK_SELECTOR = 16015286601757825753; // Ethereum Sepolia selector (remote also locks)

    address internal token;
    address internal owner;
    ERC20LockBox internal lockBox;
    LockReleaseTokenPool internal pool;

    uint256 internal constant AMOUNT = 100e18;

    function setUp() public override {
        super.setUp();
        token = deployTokenFixture();
        owner = _scriptBroadcaster();
        vm.setEnv("TOKEN", vm.toString(token));

        // README order, step 1: deploy the lockbox (no authorized callers yet — the gate is proven below).
        uint256 nonceBox = vm.getNonce(owner);
        new DeployERC20LockBox().run();
        lockBox = ERC20LockBox(vm.computeCreateAddress(owner, nonceBox));
        assertGt(address(lockBox).code.length, 0, "lockbox not deployed");

        // README order, step 2: deploy the LockReleaseTokenPool pointed at the lockbox.
        // Use the CHAIN-SCOPED `ETHEREUM_SEPOLIA_LOCK_BOX` (this fork is Sepolia), NEVER the bare inline
        // `LOCK_BOX` alias. `vm.setEnv` is process-wide and never unset: a bare `LOCK_BOX` would leak into
        // every parallel suite that resolves a lockbox (the RegistryResolution / DepositToLockBox tests
        // assert on the bare-alias rung), silently poisoning them. The chain-scoped name is namespaced to
        // Sepolia, so it cannot collide with the throwaway-chain resolution tests. `getDeployedLockBox`
        // reads `{CHAIN}_LOCK_BOX` after the bare alias, so the pool deploy below still resolves it.
        vm.setEnv("ETHEREUM_SEPOLIA_LOCK_BOX", vm.toString(address(lockBox)));
        uint256 noncePool = vm.getNonce(owner);
        new DeployLockReleaseTokenPool().run();
        pool = LockReleaseTokenPool(vm.computeCreateAddress(owner, noncePool));
        assertGt(address(pool).code.length, 0, "pool not deployed");
    }

    // ── Fixture wiring (README order) ───────────────────────────────────────────

    function test_Fixture_BuiltInReadmeOrder() public view {
        assertEq(pool.getLockBox(), address(lockBox), "pool -> lockbox wired at deploy");
        assertEq(address(lockBox.getToken()), token, "lockbox holds the fixture token");
        assertTrue(lockBox.isTokenSupported(token), "token supported by lockbox");
        // Step 3 (authorize the pool) has NOT run yet: the lockbox has no authorized callers.
        assertEq(lockBox.getAllAuthorizedCallers().length, 0, "no authorized callers before step 3");
    }

    // ── README order, step 3: authorize the pool on the lockbox ─────────────────

    function test_AuthorizePoolOnLockBox() public {
        address[] memory adds = new address[](1);
        adds[0] = address(pool);
        _exec(owner, CctActions.applyAuthorizedCallerUpdates(address(lockBox), adds, new address[](0)));

        address[] memory callers = lockBox.getAllAuthorizedCallers();
        assertEq(callers.length, 1, "pool authorized");
        assertEq(callers[0], address(pool), "the pool is the authorized caller");
    }

    // ── The invariant: deposit/withdraw work ONLY after authorization ───────────

    function test_Deposit_RevertsBeforeAuthorization() public {
        address operator = makeAddr("operatorUnauth");
        deal(token, operator, AMOUNT);
        CctActions.Call[] memory dep = CctActions.lockboxDeposit(address(lockBox), token, AMOUNT);
        // approve (call 0) succeeds; the deposit (call 1) must revert — unauthorized caller.
        vm.prank(operator);
        (bool okApprove,) = dep[0].target.call(dep[0].data);
        assertTrue(okApprove, "approve ok");
        vm.prank(operator);
        (bool okDeposit, bytes memory ret) = dep[1].target.call(dep[1].data);
        assertFalse(okDeposit, "deposit must revert before authorization");
        assertEq(bytes4(ret), bytes4(keccak256("UnauthorizedCaller(address)")), "UnauthorizedCaller");
    }

    /// @dev Pattern 1 — single-lock-chain: this chain LOCKs (deposit) and RELEASEs (withdraw); the remote
    ///      chain burns/mints. An authorized operator round-trips liquidity through the lockbox.
    function test_Pattern_SingleLockChain_DepositWithdrawRoundTrip() public {
        _wireLane(SINGLE_LOCK_CHAIN_SELECTOR, address(0xB0740B), address(0x70CE0A));
        _authorizeAndRoundTrip();
    }

    /// @dev Pattern 2 — lock-and-lock: BOTH chains lock/release; locally the mechanics are the same
    ///      deposit(lock)/withdraw(release) through the lockbox, which is what we exercise here.
    function test_Pattern_LockAndLock_DepositWithdrawRoundTrip() public {
        _wireLane(LOCK_AND_LOCK_SELECTOR, address(0x10C11A), address(0x70CE1B));
        _authorizeAndRoundTrip();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _wireLane(uint64 selector, address remotePool, address remoteToken) internal {
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
        _exec(owner, CctActions.applyChainUpdates(address(pool), new uint64[](0), updates));
        assertTrue(pool.isSupportedChain(selector), "lane wired");
    }

    /// @dev Authorize an operator (the authorize step deposit/withdraw depend on), then lock (deposit) and
    ///      release (withdraw), asserting the lockbox balance is conserved across the round-trip.
    function _authorizeAndRoundTrip() internal {
        address operator = address(0x09E7A704);
        deal(token, operator, AMOUNT);

        address[] memory adds = new address[](1);
        adds[0] = operator;
        _exec(owner, CctActions.applyAuthorizedCallerUpdates(address(lockBox), adds, new address[](0)));

        uint256 boxBefore = IERC20(token).balanceOf(address(lockBox));

        // LOCK: approve + deposit as one batch.
        CctActions.Call[] memory dep = CctActions.lockboxDeposit(address(lockBox), token, AMOUNT);
        assertEq(dep.length, 2, "deposit batch = approve + deposit");
        _exec(operator, dep);
        assertEq(IERC20(token).balanceOf(address(lockBox)), boxBefore + AMOUNT, "lock landed in lockbox");
        assertEq(IERC20(token).balanceOf(operator), 0, "operator liquidity locked");

        // RELEASE: withdraw back to the operator.
        _exec(operator, CctActions.lockboxWithdraw(address(lockBox), token, AMOUNT, operator));
        assertEq(IERC20(token).balanceOf(address(lockBox)), boxBefore, "lockbox balance conserved after release");
        assertEq(IERC20(token).balanceOf(operator), AMOUNT, "release returned liquidity");
    }
}
