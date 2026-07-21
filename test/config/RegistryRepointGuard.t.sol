// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @dev External wrapper so the internal library view is reachable from an external call frame and
/// so the tests drive the deterministic core directly (the context-aware wrappers no-op under
/// `forge test`). `wouldRepointActive` now returns the RAW string `previous`; the wrapper reduces it to
/// an EVM `address` (empty → address(0)) so the address-typed truth table below stays unchanged.
contract RepointHarness {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function wouldRepointActive(string memory sel, string memory role, address addr)
        external
        view
        returns (bool repoints, address previous)
    {
        string memory prev;
        (repoints, prev) = RegistryWriter._wouldRepointActive(sel, role, VM.toString(addr));
        previous = bytes(prev).length == 0 ? address(0) : VM.parseAddress(prev);
    }

    function setActive(string memory sel, string memory role, address addr) external {
        RegistryWriter._setActive(sel, role, addr);
    }

    function read(string memory sel, string memory role) external view returns (address) {
        return RegistryWriter._read(sel, role);
    }
}

/// @notice The `active[role]` REPOINT guard: `wouldRepointActive` is the deterministic view that
/// `setActive`/`recordDeterministic` gate their loud console warning on when a single-valued `active`
/// pointer is about to be moved off an existing fixture onto a different address (observed live:
/// deploying a second token on a chain silently hijacked `active.token`). The behavior does NOT
/// change - the repoint still happens - so only the decision helper is unit-testable; these tests
/// pin its truth table.
///
/// Cleanup is REVERT-SAFE and done in `setUp()` (before every test), NEVER at end-of-test: a test
/// that reverts mid-body would otherwise leak its throwaway `project/zz-scratch-*.json` (gitignored,
/// invisible to `git status`), and an end-of-test `removeFile` was the earlier poison-pill. Each test
/// owns a distinct throwaway `zz-scratch-*` selectorName.
contract RegistryRepointGuardTest is Test {
    RepointHarness internal harness;

    // Distinct throwaway selectorNames (zz-scratch-*, gitignored) - one per test.
    string internal constant SEL_FIRST_SET = "zz-scratch-repoint-firstset";
    string internal constant SEL_SAME_ADDR = "zz-scratch-repoint-sameaddr";
    string internal constant SEL_REPOINT = "zz-scratch-repoint-repoint";

    address internal constant ADDR_OLD = address(0x1111111111111111111111111111111111111111);
    address internal constant ADDR_NEW = address(0x2222222222222222222222222222222222222222);

    /// @dev Revert-safe cleanup BEFORE each test (never after): guarantees every test starts from a
    /// clean slate even if a prior run leaked a file, and no test relies on end-of-test deletion.
    function setUp() public {
        harness = new RepointHarness();
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        ProjectScratch.clean(SEL_FIRST_SET);
        ProjectScratch.clean(SEL_SAME_ADDR);
        ProjectScratch.clean(SEL_REPOINT);
    }

    // (1) First set: no active[role] yet -> NOT a repoint, previous is address(0).
    function test_WouldRepoint_FirstSet_ReturnsFalseZero() public view {
        (bool repoints, address previous) = harness.wouldRepointActive(SEL_FIRST_SET, "token", ADDR_NEW);
        assertFalse(repoints, "first set is never a repoint");
        assertEq(previous, address(0), "no previous pointer on first set");
    }

    // (2) Idempotent re-set: active[role] already == addr -> NOT a repoint, previous is that address.
    function test_WouldRepoint_SameAddressReset_ReturnsFalseSame() public {
        harness.setActive(SEL_SAME_ADDR, "token", ADDR_OLD);
        (bool repoints, address previous) = harness.wouldRepointActive(SEL_SAME_ADDR, "token", ADDR_OLD);
        assertFalse(repoints, "re-setting the same address is not a repoint");
        assertEq(previous, ADDR_OLD, "previous is the unchanged address");
        ProjectScratch.clean(SEL_SAME_ADDR);
    }

    // (3) Overwrite a DIFFERENT non-zero address -> repoints=true, previous is the old address. The
    //     repoint still happens (behavior unchanged) - assert the pointer moved after the warned set.
    function test_WouldRepoint_DifferentNonZero_ReturnsTrueOld() public {
        harness.setActive(SEL_REPOINT, "token", ADDR_OLD);
        (bool repoints, address previous) = harness.wouldRepointActive(SEL_REPOINT, "token", ADDR_NEW);
        assertTrue(repoints, "overwriting a different non-zero pointer is a repoint");
        assertEq(previous, ADDR_OLD, "previous is the address being repointed away from");

        // Warning is advisory only: the repoint is NOT blocked.
        harness.setActive(SEL_REPOINT, "token", ADDR_NEW);
        assertEq(harness.read(SEL_REPOINT, "token"), ADDR_NEW, "repoint still applied (warn-only)");
        ProjectScratch.clean(SEL_REPOINT);
    }
}
