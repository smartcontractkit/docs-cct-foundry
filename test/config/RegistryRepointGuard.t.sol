// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @dev External wrapper so the internal library view is reachable from an external call frame and
/// so the tests drive the deterministic core directly (the context-aware wrappers no-op under
/// `forge test`).
contract RepointHarness {
    function wouldRepointActive(uint256 chainId, string memory role, address addr)
        external
        view
        returns (bool repoints, address previous)
    {
        return RegistryWriter.wouldRepointActive(chainId, role, addr);
    }

    function setActive(uint256 chainId, string memory role, address addr) external {
        RegistryWriter.setActive(chainId, role, addr);
    }

    function read(uint256 chainId, string memory role) external view returns (address) {
        return RegistryWriter.read(chainId, role);
    }
}

/// @notice The `active[role]` REPOINT guard: `wouldRepointActive` is the deterministic view that
/// `setActive`/`recordDeterministic` gate their loud console warning on when a single-valued `active`
/// pointer is about to be moved off an existing fixture onto a different address (observed live:
/// deploying a second token on a chain silently hijacked `active.token`). The behavior does NOT
/// change — the repoint still happens — so only the decision helper is unit-testable; these tests
/// pin its truth table.
///
/// Cleanup is REVERT-SAFE and done in `setUp()` (before every test), NEVER at end-of-test: a test
/// that reverts mid-body would otherwise leak its throwaway `addresses/<chainId>.json`, and an
/// end-of-test `deleteFile` was the earlier poison-pill. Each test owns a distinct throwaway chainId.
contract RegistryRepointGuardTest is Test {
    RepointHarness internal harness;

    // Distinct throwaway chain IDs (well outside any real chainId) — one per test.
    uint256 internal constant CHAIN_FIRST_SET = 900_000_000_201;
    uint256 internal constant CHAIN_SAME_ADDR = 900_000_000_202;
    uint256 internal constant CHAIN_REPOINT = 900_000_000_203;

    address internal constant ADDR_OLD = address(0x1111111111111111111111111111111111111111);
    address internal constant ADDR_NEW = address(0x2222222222222222222222222222222222222222);

    function _path(uint256 chainId) internal pure returns (string memory) {
        return string.concat("addresses/", vm.toString(chainId), ".json");
    }

    /// @dev Revert-safe cleanup BEFORE each test (never after): guarantees every test starts from a
    /// clean slate even if a prior run leaked a file, and no test relies on end-of-test deletion.
    function setUp() public {
        harness = new RepointHarness();
        uint256[3] memory chains = [CHAIN_FIRST_SET, CHAIN_SAME_ADDR, CHAIN_REPOINT];
        for (uint256 i = 0; i < chains.length; i++) {
            string memory p = _path(chains[i]);
            if (vm.exists(p)) vm.removeFile(p);
        }
    }

    // (1) First set: no active[role] yet -> NOT a repoint, previous is address(0).
    function test_WouldRepoint_FirstSet_ReturnsFalseZero() public view {
        (bool repoints, address previous) = harness.wouldRepointActive(CHAIN_FIRST_SET, "token", ADDR_NEW);
        assertFalse(repoints, "first set is never a repoint");
        assertEq(previous, address(0), "no previous pointer on first set");
    }

    // (2) Idempotent re-set: active[role] already == addr -> NOT a repoint, previous is that address.
    function test_WouldRepoint_SameAddressReset_ReturnsFalseSame() public {
        harness.setActive(CHAIN_SAME_ADDR, "token", ADDR_OLD);
        (bool repoints, address previous) = harness.wouldRepointActive(CHAIN_SAME_ADDR, "token", ADDR_OLD);
        assertFalse(repoints, "re-setting the same address is not a repoint");
        assertEq(previous, ADDR_OLD, "previous is the unchanged address");
    }

    // (3) Overwrite a DIFFERENT non-zero address -> repoints=true, previous is the old address. The
    //     repoint still happens (behavior unchanged) — assert the pointer moved after the warned set.
    function test_WouldRepoint_DifferentNonZero_ReturnsTrueOld() public {
        harness.setActive(CHAIN_REPOINT, "token", ADDR_OLD);
        (bool repoints, address previous) = harness.wouldRepointActive(CHAIN_REPOINT, "token", ADDR_NEW);
        assertTrue(repoints, "overwriting a different non-zero pointer is a repoint");
        assertEq(previous, ADDR_OLD, "previous is the address being repointed away from");

        // Warning is advisory only: the repoint is NOT blocked.
        harness.setActive(CHAIN_REPOINT, "token", ADDR_NEW);
        assertEq(harness.read(CHAIN_REPOINT, "token"), ADDR_NEW, "repoint still applied (warn-only)");
    }
}
