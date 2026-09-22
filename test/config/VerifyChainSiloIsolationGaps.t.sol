// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {LaneReconcileScratch} from "./VerifyChainLaneReconcile.t.sol";
import {MockSiloedPool, MockSiloedLockBox} from "./VerifyChainSiloedLockBoxes.t.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";

/// @dev A box that implements only the ILockBox surface (no getAllAuthorizedCallers) - the shape a custom
///      adapter would have.
contract MockIlockBoxOnly {
    address internal immutable i_token;

    constructor(address token) {
        i_token = token;
    }

    function isTokenSupported(address token) external view returns (bool) {
        return token == i_token;
    }
}

/// @dev A siloed pool that also answers the rate-limit getter, so a declared 0/0 lane reconciles clean and
///      only the lock-and-lock rung speaks.
contract MockSiloedPoolWithBuckets is MockSiloedPool {
    constructor(string memory version, address token_) MockSiloedPool(version, token_) {}

    function getCurrentRateLimiterState(uint64, bool)
        external
        pure
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound)
    {}
}

/// @notice The silo-isolation rung must never answer "looks fine" when it could not look: a missing chain
/// file, an absent or malformed peer store, a box for a chain the pool dropped, a narrower custom box.
contract VerifyChainSiloIsolationGapsTest is LaneReconcileScratch {
    address internal constant TOKEN = address(0x7171);

    function _names(string memory t) internal pure returns (string memory home, string memory a, string memory b) {
        home = string.concat("zz-scratch-repro-", t, "-home");
        a = string.concat("zz-scratch-repro-", t, "-a");
        b = string.concat("zz-scratch-repro-", t, "-b");
    }

    function _clean(string memory t) private {
        (string memory home, string memory a, string memory b) = _names(t);
        _cleanupScratchOne(home);
        _cleanupScratchOne(a);
        _cleanupScratchOne(b);
    }

    /// F2: B's chain file is missing from config/chains, so the pair is skipped - silently.
    function test_Warn_SelectorWithNoChainFile() public {
        string memory t = "f2";
        _clean(t);
        (string memory HOME, string memory A, string memory B) = _names(t);
        uint64 SEL_A = 7_101_000_000_000_000_001;
        uint64 SEL_B = 7_101_000_000_000_000_002;
        _writeScratchChain(HOME, 710_100_003, 7_101_000_000_000_000_003);
        _writeScratchChain(A, 710_100_001, SEL_A);
        // B: NO chain file written on purpose.

        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(SEL_A);
        pool.addChain(SEL_B);
        address boxA = address(new MockSiloedLockBox(TOKEN, address(pool)));
        address boxB = address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(SEL_A, boxA);
        pool.mapBox(SEL_B, boxB);

        ProjectStore._seedIfAbsent(A);
        ProjectStore._seedIfAbsent(B);
        _declareLane(A, B, _laneEntry(SEL_B, 1, 1, ""));

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        _clean(t);
        assertEq(fails, 0, "an unreadable catalog is not proof of a hazard");
        assertGt(warns, 0, "a boxed selector with no chain file must be reported, not skipped in silence");
    }

    /// F3: A's project store is unreadable (malformed JSON) -> _declaredLaneNames returns "no lanes".
    function test_Fail_UnreadablePeerStore() public {
        string memory t = "f3";
        _clean(t);
        (string memory HOME, string memory A, string memory B) = _names(t);
        uint64 SEL_A = 7_102_000_000_000_000_001;
        uint64 SEL_B = 7_102_000_000_000_000_002;
        _writeScratchChain(HOME, 710_200_003, 7_102_000_000_000_000_003);
        _writeScratchChain(A, 710_200_001, SEL_A);
        _writeScratchChain(B, 710_200_002, SEL_B);

        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(SEL_A);
        pool.addChain(SEL_B);
        address boxA = address(new MockSiloedLockBox(TOKEN, address(pool)));
        address boxB = address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(SEL_A, boxA);
        pool.mapBox(SEL_B, boxB);

        ProjectStore._seedIfAbsent(A);
        ProjectStore._seedIfAbsent(B);
        _declareLane(A, B, _laneEntry(SEL_B, 1, 1, ""));
        // Corrupt A's store AFTER declaring the lane: the hazard is real, the evidence is unreadable.
        vm.writeFile(_projPath(A), "{ this is not json");

        (uint256 fails,) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        _clean(t);
        assertEq(fails, 1, "a peer store that exists but does not parse FAILs: could not look is not looks fine");
    }

    /// F4: a box mapped to a chain the pool no longer supports still takes part in the pair check.
    function test_Pass_StaleBoxForRemovedChain() public {
        string memory t = "f4";
        _clean(t);
        (string memory HOME, string memory A, string memory B) = _names(t);
        uint64 SEL_A = 7_103_000_000_000_000_001;
        uint64 SEL_B = 7_103_000_000_000_000_002;
        _writeScratchChain(HOME, 710_300_003, 7_103_000_000_000_000_003);
        _writeScratchChain(A, 710_300_001, SEL_A);
        _writeScratchChain(B, 710_300_002, SEL_B);

        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(SEL_A); // B was REMOVED from the pool (RemoveChain), A is still live.
        address boxA = address(new MockSiloedLockBox(TOKEN, address(pool)));
        address boxB = address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(SEL_A, boxA);
        pool.mapBox(SEL_B, boxB); // stale: configureLockBoxes cannot remove it

        ProjectStore._seedIfAbsent(A);
        ProjectStore._seedIfAbsent(B);
        _declareLane(A, B, _laneEntry(SEL_B, 1, 1, ""));

        (uint256 fails,) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        _clean(t);
        assertEq(fails, 0, "a box left behind for a chain the pool dropped carries no route, so it cannot FAIL");
    }

    /// F7: the peer runs a SILOED lock-release pool; the substring match calls it a lock-and-lock bridge.
    function test_Warn_SiloedPeerUsesSiloedWording() public {
        string memory t = "f7";
        _clean(t);
        (string memory HOME, string memory PEER,) = _names(t);
        uint64 peerSelector = 7_104_000_000_000_000_001;
        _writeScratchChain(HOME, 710_400_001, 7_104_000_000_000_000_002);
        _writeScratchChain(PEER, 710_400_002, peerSelector);

        ProjectStore._seedIfAbsent(PEER);
        address peerPool = address(0xBEEF);
        vm.writeJson(
            string.concat(
                "{\"active\":{\"tokenPool\":\"",
                vm.toString(peerPool),
                "\"},\"deployments\":{\"ZZ_SiloedLockReleaseTokenPool_2.0.0\":\"",
                vm.toString(peerPool),
                "\"}}"
            ),
            _projPath(PEER),
            ".addresses"
        );
        _declareLane(HOME, PEER, _laneEntry(peerSelector, 0, 0, ""));

        MockSiloedPoolWithBuckets pool = new MockSiloedPoolWithBuckets("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(peerSelector);
        address box = address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(peerSelector, box);

        VerifyChain checker = new VerifyChain();
        (, uint256 warns) = checker.checkLanesOnChainForTest(HOME, address(pool));
        string memory warned = checker.lastWarnForTest();
        _clean(t);
        assertGt(warns, 0, "a siloed peer still warns");
        // The wording must name the silo, not the plain two-sided bridge docs/operations/pools.md distinguishes.
        assertTrue(vm.indexOf(warned, "siloed lock-release pool") != type(uint256).max, warned);
        assertTrue(vm.indexOf(warned, "per silo") != type(uint256).max, warned);
    }

    /// F8: a box implementing only ILockBox (no getAllAuthorizedCallers) hard-FAILs the lock box rung.
    function test_Warn_IlockBoxOnlyAdapterIsUnverified() public {
        string memory t = "f8";
        _clean(t);
        (string memory HOME, string memory A,) = _names(t);
        uint64 SEL_A = 7_105_000_000_000_000_001;
        _writeScratchChain(HOME, 710_500_003, 7_105_000_000_000_000_003);
        _writeScratchChain(A, 710_500_001, SEL_A);

        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(SEL_A);
        pool.mapBox(SEL_A, address(new MockIlockBoxOnly(TOKEN)));

        ProjectStore._seedIfAbsent(A);

        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        _clean(t);
        assertEq(fails, 0, "a box that answers ILockBox is not broken just because it exposes no caller list");
        assertGt(warns, 0, "but the authorization is unverified, and says so");
    }
}
