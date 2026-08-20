// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";
import {EmptyReturn} from "../fixtures/ReturnDataShells.sol";
import {PoolVersion} from "../../script/utils/PoolVersion.s.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";

/// @notice The doctor must reach a VERDICT for every pool address, including ones it cannot read.
/// `_reconcileLanesWithPool` resolves the pool's `typeAndVersion` first; before `TolerantCall` that
/// read took the whole run down with `EvmError: Revert`. The doctor resolves the pool from
/// `addresses.active.tokenPool`, and in a `MODE=safe` workflow the Safe address sits in that same
/// file - so `make adopt-token TOKEN_POOL=<safe>`, or a hand edit, puts one there.
contract DoctorSurvivesWeirdPoolTest is Test {
    string internal constant SEL_SHELL = "zz-scratch-weirdpool-shell";
    string internal constant SEL_CODELESS = "zz-scratch-weirdpool-codeless";

    function setUp() public {
        ProjectScratch.clean(SEL_SHELL);
    }

    /// A WARN is the right answer: the pool exists, it just cannot be identified. With no store on
    /// disk there are no lanes to check, so nothing else in this rung can warn and `warns == 1` is
    /// exact - but a count cannot name a warning, which is what the resolver assertions below do.
    function test_PoolAnsweringWithUndecodableData_WarnsInsteadOfKillingTheRun() public {
        address shell = address(new EmptyReturn());
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.checkLanesOnChainForTest(SEL_SHELL, shell);
        assertEq(fails, 0, "an unreadable pool is not a failed check");
        assertEq(warns, 1, "exactly one warning, the unidentifiable-pool one");

        // What the rung actually saw, so the warning above cannot be the right count for a wrong reason.
        (bool ok, PoolVersions.Version version, string memory full) = PoolVersion._tryResolve(shell);
        assertFalse(ok, "the resolver must report the pool as unidentified");
        assertEq(uint256(version), uint256(PoolVersions.Version.UNKNOWN), "and not guess a version");
        assertEq(full, "", "an undecodable answer yields no string, not a garbage one");
    }

    /// The half that was already guarded, kept so a regression cannot quietly trade one for the other.
    function test_CodelessPool_StillWarns() public {
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.checkLanesOnChainForTest(SEL_CODELESS, address(0xdead));
        assertEq(fails, 0, "a codeless pool is not a failed check either");
        assertEq(warns, 1, "and is still reported, once");
        ProjectScratch.clean(SEL_CODELESS);
    }
}
