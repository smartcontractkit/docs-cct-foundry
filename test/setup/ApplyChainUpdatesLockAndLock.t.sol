// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ApplyChainUpdates} from "../../script/setup/ApplyChainUpdates.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @notice ApplyChainUpdates refuses to wire a lane whose peer also runs a lock-release pool: both ends
/// would pay releases out of their own liquidity, so the lane drains one way from the moment it applies.
/// The peer's pool TYPE is only knowable from its project store's deployments key, so these cases turn on
/// what that store says - including saying nothing.
contract ApplyChainUpdatesLockAndLockTest is LaneReconcileScratch {
    string[5] internal SUITES = ["lockrelease", "siloed", "burnmint", "nostore", "localbm"];
    uint64 internal constant PEER_SELECTOR_BASE = 9_911_000_000_000_000_001;

    function setUp() public {
        for (uint256 i = 0; i < SUITES.length; i++) {
            _cleanupScratchOne(string.concat("zz-scratch-lal-", SUITES[i]));
        }
    }

    /// @dev A peer chain whose store names `poolKey` as its active pool, and the reason the script gives
    ///      for a lane to it ("" = allowed).
    function _reasonFor(string memory suite, uint256 seed, string memory poolKey)
        internal
        returns (string memory reason)
    {
        return _reasonFor(suite, seed, poolKey, "LockReleaseTokenPool 2.0.0");
    }

    /// @dev `localType` is what THIS chain's pool reports; the guard only speaks for a lock-release local.
    function _reasonFor(string memory suite, uint256 seed, string memory poolKey, string memory localType)
        internal
        returns (string memory reason)
    {
        string memory peer = string.concat("zz-scratch-lal-", suite);
        uint64 selector = uint64(PEER_SELECTOR_BASE + seed * 1_000_000);
        _writeScratchChain(peer, 991_100 + seed, selector);

        if (bytes(poolKey).length > 0) {
            ProjectStore._seedIfAbsent(peer);
            address peerPool = address(uint160(0xB0B0000 + seed));
            vm.writeJson(
                string.concat(
                    "{\"active\":{\"tokenPool\":\"",
                    vm.toString(peerPool),
                    "\"},\"deployments\":{\"",
                    poolKey,
                    "\":\"",
                    vm.toString(peerPool),
                    "\"}}"
                ),
                _projPath(peer),
                ".addresses"
            );
        }

        ApplyChainUpdates script = new ApplyChainUpdates();
        script.initHelperConfigForTest();
        reason = script.lockAndLockReasonForTest(localType, selector);
        _cleanupScratchOne(peer);
    }

    function test_Refuses_PeerRunsLockRelease() public {
        string memory reason = _reasonFor("lockrelease", 1, "ZZ_LockReleaseTokenPool_2.0.0");
        assertTrue(bytes(reason).length > 0, "a lock-release peer must be refused");
        assertTrue(vm.indexOf(reason, "LockAndLockLane") != type(uint256).max, reason);
        assertTrue(vm.indexOf(reason, "ACK_LOCK_AND_LOCK=true") != type(uint256).max, "names the override");
    }

    /// @dev Two silos of one pool are the worse case of the same hazard, and the key still carries the type.
    function test_Refuses_PeerRunsSiloedLockRelease() public {
        string memory reason = _reasonFor("siloed", 2, "ZZ_SiloedLockReleaseTokenPool_2.0.0");
        assertTrue(bytes(reason).length > 0, "a siloed lock-release peer must be refused too");
    }

    function test_Allows_PeerRunsBurnMint() public {
        assertEq(_reasonFor("burnmint", 3, "ZZ_BurnMintTokenPool_2.0.0"), "", "mint/burn peers are the normal mesh");
    }

    /// @dev Mint/burn on THIS side absorbs the imbalance - lock-release facing burn-mint is the normal
    ///      CCT shape, not a bridge, so the guard must stay quiet however the peer is configured.
    function test_Allows_LocalPoolIsBurnMint() public {
        string memory reason = _reasonFor("localbm", 5, "ZZ_LockReleaseTokenPool_2.0.0", "BurnMintTokenPool 2.0.0");
        assertEq(reason, "", "a burn-mint local pool is never half of a lock-and-lock lane");
    }

    /// @dev A peer this operator does not manage says nothing about the peer's pool, and absence of
    ///      evidence must not block a legitimate lane.
    function test_Allows_PeerWithNoStore() public {
        assertEq(_reasonFor("nostore", 4, ""), "", "no peer store, no claim");
    }
}
