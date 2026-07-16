// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainMultiPoolTest — the multi-pool ambiguity WARN (`_warnMultiPoolAmbiguity`, offline)
/// @notice `addresses.active.tokenPool` is single-valued per chain: when `deployments{}` holds two or
/// more token pools (a multi-token chain), the zero-export resolution serves ONE pool for every token.
/// The doctor's registry rung surfaces that with exactly one WARN naming the count and the
/// `{CHAIN}_TOKEN_POOL` targeted override; zero or one pool stays silent. WARN-only (never FAIL), no
/// RPC — a pure file read — so this suite pins the (fails, warns) contract as a unit test via
/// `warnMultiPoolAmbiguityForTest`. Each test writes its own uniquely-named scratch project file
/// (suites run in parallel and share the filesystem) and cleans it in setUp() (revert-safe).
contract VerifyChainMultiPoolTest is Test {
    string internal constant SEL_NONE = "zz-scratch-multipool-none";
    string internal constant SEL_ONE = "zz-scratch-multipool-one";
    string internal constant SEL_TWO = "zz-scratch-multipool-two";
    string internal constant SEL_MIXED = "zz-scratch-multipool-mixed";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[4] memory sels = [SEL_NONE, SEL_ONE, SEL_TWO, SEL_MIXED];
        for (uint256 i = 0; i < sels.length; i++) {
            string memory p = ProjectStore.path(sels[i]);
            if (vm.exists(p)) vm.removeFile(p);
        }
    }

    /// @dev Per-name variant for end-of-test cleanup (a test removes ONLY the file it owns; suite
    /// siblings run in parallel).
    function _clean(string memory sel) private {
        string memory p = ProjectStore.path(sel);
        if (vm.exists(p)) vm.removeFile(p);
    }

    /// @dev Writes a schema-3 project store for `name` whose `deployments{}` body is the given
    /// comma-separated `"key":"addr"` fragment ("" for empty). Only `deployments{}` matters to the
    /// multi-pool check; the other subtrees stay empty.
    function _writeProject(string memory name, string memory deploymentsBody) internal {
        string memory json = string.concat(
            "{\"addresses\":{\"active\":{},\"deployments\":{",
            deploymentsBody,
            "}},\"lanes\":{},\"roles\":{},\"schema\":3}"
        );
        vm.writeFile(ProjectStore.path(name), json);
    }

    // ------------------------------------------------------------ clean: zero / one pool → silent

    /// @dev No pool deployed at all: nothing ambiguous, silent.
    function test_MultiPool_NoPool_Silent() public {
        _writeProject(SEL_NONE, "\"AAA_Token\":\"0x0000000000000000000000000000000000000A01\"");
        (uint256 fails, uint256 warns) = new VerifyChain().warnMultiPoolAmbiguityForTest(SEL_NONE);
        assertEq(fails, 0, "multi-pool ambiguity is WARN-only, never FAIL");
        assertEq(warns, 0, "no pool deployed must be silent");
        _clean(SEL_NONE);
    }

    /// @dev Exactly one pool: `active.tokenPool` is unambiguous, silent. This is the common case and
    /// must never regress into a noisy WARN.
    function test_MultiPool_SinglePool_Silent() public {
        _writeProject(SEL_ONE, "\"AAA_BurnMintTokenPool_2.0.0\":\"0x0000000000000000000000000000000000000A02\"");
        (uint256 fails, uint256 warns) = new VerifyChain().warnMultiPoolAmbiguityForTest(SEL_ONE);
        assertEq(fails, 0, "a single pool must never FAIL");
        assertEq(warns, 0, "a single pool is unambiguous - silent");
        _clean(SEL_ONE);
    }

    // ------------------------------------------------------------ induced: two pools → 1 WARN

    /// @dev Two distinct pools in `deployments{}` (a second token's pool landed on the same chain):
    /// exactly one WARN, zero FAIL. The WARN text (count + the `{CHAIN}_TOKEN_POOL` remedy) is composed
    /// inline in `_warnMultiPoolAmbiguity`; console output is not in-test capturable, so the contract
    /// asserted here is the (fails, warns) tally, as in the other doctor-rung suites.
    function test_MultiPool_TwoPools_OneWarn() public {
        _writeProject(
            SEL_TWO,
            "\"AAA_BurnMintTokenPool_2.0.0\":\"0x0000000000000000000000000000000000000A03\","
            "\"BBB_LockReleaseTokenPool_2.0.0\":\"0x0000000000000000000000000000000000000A04\""
        );
        (uint256 fails, uint256 warns) = new VerifyChain().warnMultiPoolAmbiguityForTest(SEL_TWO);
        assertEq(fails, 0, "two pools must never FAIL (WARN-only)");
        assertEq(warns, 1, "two pools with one active.tokenPool must emit exactly one WARN");
        _clean(SEL_TWO);
    }

    // ------------------------------------------------------------ non-pool artifacts don't count

    /// @dev One pool plus non-pool artifacts (token, lock box, hooks): only entries whose key carries
    /// the pool marker count, so this stays silent — the counter must not misread other artifact kinds.
    function test_MultiPool_NonPoolArtifactsDontCount_Silent() public {
        _writeProject(
            SEL_MIXED,
            "\"AAA_Token\":\"0x0000000000000000000000000000000000000A05\","
            "\"AAA_BurnMintTokenPool_2.0.0\":\"0x0000000000000000000000000000000000000A06\","
            "\"AAA_LockBox\":\"0x0000000000000000000000000000000000000A07\","
            "\"AAA_BurnMint_PoolHooks\":\"0x0000000000000000000000000000000000000A08\""
        );
        (uint256 fails, uint256 warns) = new VerifyChain().warnMultiPoolAmbiguityForTest(SEL_MIXED);
        assertEq(fails, 0, "mixed artifacts must never FAIL");
        assertEq(warns, 0, "token/lockBox/hooks entries are not pools - a single pool stays silent");
        _clean(SEL_MIXED);
    }
}
