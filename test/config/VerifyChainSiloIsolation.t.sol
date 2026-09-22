// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {LaneReconcileScratch} from "./VerifyChainLaneReconcile.t.sol";
import {MockSiloedPool, MockSiloedLockBox} from "./VerifyChainSiloedLockBoxes.t.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";

/// @dev A 2.0 LockRelease pool with one lane and disabled buckets, so a declared 0/0 lane reconciles clean
/// and only the lock-and-lock rung can speak.
contract MockLockReleaseV2Pool {
    uint64 private immutable i_selector;

    constructor(uint64 selector) {
        i_selector = selector;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "LockReleaseTokenPool 2.0.0";
    }

    function isSupportedChain(uint64 selector) external view returns (bool) {
        return selector == i_selector;
    }

    function getSupportedChains() external view returns (uint64[] memory chains) {
        chains = new uint64[](1);
        chains[0] = i_selector;
    }

    function getCurrentRateLimiterState(uint64, bool)
        external
        pure
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound)
    {}
}

/// @notice doctor's silo-isolation rung: two remotes of one siloed pool that are served by DIFFERENT lock
/// boxes must not declare a lane to each other, or tokens locked for one are released from the other's box.
/// Chains mapped to the SAME box share liquidity by design and stay allowed.
contract VerifyChainSiloIsolationTest is LaneReconcileScratch {
    // One set of basenames per test: forge runs a suite's tests in parallel and they would race.
    string[5] internal SUITES = ["fail", "sharedbox", "nolane", "reverse", "lockandlock"];
    address internal constant TOKEN = address(0x7070);

    function setUp() public {
        for (uint256 i = 0; i < SUITES.length; i++) {
            _cleanOne(SUITES[i]);
        }
    }

    function _names(string memory t) internal pure returns (string memory home, string memory a, string memory b) {
        home = string.concat("zz-scratch-siloiso-", t, "-home");
        a = string.concat("zz-scratch-siloiso-", t, "-a");
        b = string.concat("zz-scratch-siloiso-", t, "-b");
    }

    function _cleanOne(string memory t) private {
        (string memory home, string memory a, string memory b) = _names(t);
        _cleanupScratchOne(home);
        _cleanupScratchOne(a);
        _cleanupScratchOne(b);
    }

    /// @dev A siloed pool serving A and B, with `sharedBox` deciding whether they share liquidity, and
    /// `laneAtoB` whether A declares a lane to B in its own store.
    function _run(string memory t, uint256 seed, bool sharedBox, bool laneAtoB, bool laneBtoA)
        internal
        returns (uint256 fails, uint256 warns)
    {
        (string memory HOME, string memory A, string memory B) = _names(t);
        uint64 SEL_A = uint64(8_878_000_000_000_000_001 + seed * 1_000_000_000);
        uint64 SEL_B = uint64(8_878_000_000_000_000_002 + seed * 1_000_000_000);
        _writeScratchChain(HOME, 887_800_000 + seed * 10, uint64(8_878_000_000_000_000_003 + seed * 1_000_000_000));
        _writeScratchChain(A, 887_800_001 + seed * 10, SEL_A);
        _writeScratchChain(B, 887_800_002 + seed * 10, SEL_B);

        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", TOKEN);
        pool.addChain(SEL_A);
        pool.addChain(SEL_B);
        address boxA = address(new MockSiloedLockBox(TOKEN, address(pool)));
        address boxB = sharedBox ? boxA : address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(SEL_A, boxA);
        pool.mapBox(SEL_B, boxB);

        ProjectStore._seedIfAbsent(A);
        ProjectStore._seedIfAbsent(B);
        if (laneAtoB) _declareLane(A, B, _laneEntry(SEL_B, 1, 1, ""));
        if (laneBtoA) _declareLane(B, A, _laneEntry(SEL_A, 1, 1, ""));

        (fails, warns) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        _cleanOne(t);
    }

    function test_Fail_TwoSilosTalkingToEachOther() public {
        (uint256 fails,) = _run("fail", 1, false, true, false);
        assertEq(fails, 1, "a lane between two differently-boxed silos must FAIL");
    }

    function test_Pass_SameBoxChainsMayTalk() public {
        (uint256 fails,) = _run("sharedbox", 2, true, true, true);
        assertEq(fails, 0, "chains sharing one box share liquidity by design");
    }

    /// @dev The route exists whichever side declared it: one finding per pair, from either store.
    function test_Fail_LaneDeclaredOnlyByTheFarSide() public {
        (uint256 fails,) = _run("reverse", 4, false, false, true);
        assertEq(fails, 1, "a lane declared only in the peer's store still breaks isolation, and is reported once");
    }

    /// @dev Lock-release on BOTH ends is a liquidity bridge: legitimate, but it drains one way, so it WARNs
    ///      rather than failing. The peer's type comes from its own store's deployments key.
    function test_Warn_LockReleaseOnBothEnds() public {
        (string memory HOME, string memory PEER,) = _names("lockandlock");
        uint64 peerSelector = 8_878_900_010_000_000_001;
        _writeScratchChain(HOME, 887_890_001, 8_878_900_020_000_000_001);
        _writeScratchChain(PEER, 887_890_002, peerSelector);

        ProjectStore._seedIfAbsent(PEER);
        address peerPool = address(0xCAFE);
        vm.writeJson(
            string.concat(
                "{\"active\":{\"tokenPool\":\"",
                vm.toString(peerPool),
                "\"},\"deployments\":{\"ZZ_LockReleaseTokenPool_2.0.0\":\"",
                vm.toString(peerPool),
                "\"}}"
            ),
            _projPath(PEER),
            ".addresses"
        );
        _declareLane(HOME, PEER, _laneEntry(peerSelector, 0, 0, ""));

        MockLockReleaseV2Pool pool = new MockLockReleaseV2Pool(peerSelector);
        (uint256 fails, uint256 warns) = new VerifyChain().checkLanesOnChainForTest(HOME, address(pool));
        assertEq(fails, 0, "a lock-and-lock lane is legitimate, never a FAIL");
        assertEq(warns, 1, "it warns once, naming the rebalancing duty");
        _cleanOne("lockandlock");
    }

    function test_Pass_DifferentBoxesWithoutALane() public {
        (uint256 fails,) = _run("nolane", 3, false, false, false);
        assertEq(fails, 0, "different boxes are the point of siloing; only a lane between them breaks it");
    }
}
