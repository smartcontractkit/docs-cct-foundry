// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @title VerifyChainCodelessArtifacts
/// @notice The doctor's registry rung code-checked `active.token` and `active.tokenPool` only, so a
/// recorded lock box, hooks contract, or any `deployments{}` entry that is not the current active
/// pointer passed clean even when nothing was ever deployed at that address. A deploy writes the store
/// during forge's simulation pass, so a `--broadcast` that fails afterwards produces exactly that
/// state. These tests pin the rung that closes it: one FAIL per codeless artifact, and silence when
/// there is no chain to read.
contract VerifyChainCodelessArtifactsTest is Test {
    // Deliberately codeless unless a test etches into them.
    address internal constant TOKEN = address(0x00000000000000000000000000000000000000A1);
    address internal constant POOL = address(0x00000000000000000000000000000000000000A2);
    address internal constant LOCKBOX = address(0x00000000000000000000000000000000000000A3);
    address internal constant HOOKS = address(0x00000000000000000000000000000000000000a4);

    bytes internal constant SOME_CODE = hex"600160005260206000f3";

    string internal constant SEL_PHANTOM = "zz-scratch-codeless-phantom";
    string internal constant SEL_ALLCODE = "zz-scratch-codeless-allcode";
    string internal constant SEL_UNFORKED = "zz-scratch-codeless-unforked";
    string internal constant SEL_NOSTORE = "zz-scratch-codeless-nostore";
    string internal constant SEL_NAMEDONLY = "zz-scratch-codeless-namedonly";
    string internal constant SEL_WIRED = "zz-scratch-codeless-wired";
    string internal constant SEL_BADVALUE = "zz-scratch-codeless-badvalue";
    string internal constant SEL_BADSHAPE = "zz-scratch-codeless-badshape";
    string internal constant SEL_NOREAD = "zz-scratch-codeless-noread";
    string internal constant SEL_TRUNC = "zz-scratch-codeless-trunc";
    string internal constant SEL_BADACTIVE = "zz-scratch-codeless-badactive";
    string internal constant SEL_MULTIPOOL = "zz-scratch-codeless-multipool";
    string internal constant SEL_ACTIVEPOOL = "zz-scratch-codeless-activepool";

    function setUp() public {
        ProjectScratch.clean(SEL_PHANTOM);
        ProjectScratch.clean(SEL_ALLCODE);
        ProjectScratch.clean(SEL_UNFORKED);
        ProjectScratch.clean(SEL_NOSTORE);
        ProjectScratch.clean(SEL_NAMEDONLY);
        ProjectScratch.clean(SEL_WIRED);
        ProjectScratch.clean(SEL_BADVALUE);
        ProjectScratch.clean(SEL_BADSHAPE);
        if (vm.isDir(ProjectStore._path(SEL_NOREAD))) vm.removeDir(ProjectStore._path(SEL_NOREAD), true);
        ProjectScratch.clean(SEL_NOREAD);
        ProjectScratch.clean(SEL_TRUNC);
        ProjectScratch.clean(SEL_BADACTIVE);
        ProjectScratch.clean(SEL_MULTIPOOL);
        ProjectScratch.clean(SEL_ACTIVEPOOL);
    }

    /// @dev A schema-3 store holding all four artifact roles plus their named `deployments` entries.
    function _writeFullStore(string memory sel) internal {
        string memory json = string.concat(
            '{"addresses":{"active":{"token":"',
            vm.toString(TOKEN),
            '","tokenPool":"',
            vm.toString(POOL),
            '","lockBox":"',
            vm.toString(LOCKBOX),
            '","poolHooks":"',
            vm.toString(HOOKS),
            '"},"deployments":{"BnM-T_Token":"',
            vm.toString(TOKEN),
            '","BnM-T_LockBox":"',
            vm.toString(LOCKBOX),
            '","BnM-T_BurnMint_PoolHooks":"',
            vm.toString(HOOKS),
            '"}},"lanes":{},"roles":{},"schema":3}'
        );
        vm.writeFile(ProjectStore._path(sel), json);
    }

    /// @dev A schema-3 store with the standard code-bearing active pair and a caller-chosen
    /// `deployments` body - the shape every well-formed fixture below varies. The deliberately
    /// malformed stores stay written out inline: their whole point is a shape a builder cannot make.
    function _writeStore(string memory sel, string memory deploymentsBody) internal {
        vm.writeFile(
            ProjectStore._path(sel),
            string.concat(
                '{"addresses":{"active":{"token":"',
                vm.toString(TOKEN),
                '","tokenPool":"',
                vm.toString(POOL),
                '"},"deployments":',
                deploymentsBody,
                '},"lanes":{},"roles":{},"schema":3}'
            )
        );
    }

    /// Every codeless `deployments` entry is named exactly once. The rung walks `deployments{}` only;
    /// it reads the active pair to skip those addresses, which stay the pointer rung's to report.
    function test_CodelessArtifacts_EachFailsOnce() public {
        _writeFullStore(SEL_PHANTOM);
        (uint256 fails, uint256 warns) = new VerifyChain().failCodelessDeploymentsForTest(SEL_PHANTOM, true);
        assertEq(warns, 0, "a recorded address with no code is a FAIL, not a WARN");
        // The rung walks `deployments{}`. Two of its three entries are codeless and reported here;
        // `BnM-T_Token` is skipped because it is `active.token`, which the pointer rung reports with
        // its own remedy. An `active` role with no `deployments` entry is checked by neither.
        assertEq(fails, 2, "the lock box and the hooks entries; the token entry is the pointer rung's to report");
        ProjectScratch.clean(SEL_PHANTOM);
    }

    /// The rung must not fire on a healthy store, or every green deploy would report a failure.
    function test_AllArtifactsHaveCode_Silent() public {
        _writeFullStore(SEL_ALLCODE);
        vm.etch(TOKEN, SOME_CODE);
        vm.etch(POOL, SOME_CODE);
        vm.etch(LOCKBOX, SOME_CODE);
        vm.etch(HOOKS, SOME_CODE);
        (uint256 fails, uint256 warns) = new VerifyChain().failCodelessDeploymentsForTest(SEL_ALLCODE, true);
        assertEq(fails, 0, "artifacts that are contracts must not FAIL");
        assertEq(warns, 0, "and must not WARN");
        ProjectScratch.clean(SEL_ALLCODE);
    }

    /// No fork means no chain to read. Reporting absence here would turn "could not check" into
    /// "is missing" on every unforked doctor run.
    function test_Unforked_ChecksNothing() public {
        _writeFullStore(SEL_UNFORKED);
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.failCodelessDeploymentsForTest(SEL_UNFORKED, false);
        assertEq(fails, 0, "an unforked run must not FAIL on code it cannot read");
        assertEq(warns, 0, "and must not WARN");
        // But it must not vanish either: a rung that goes silent turns "could not look" into "looks
        // fine". The sibling rung in the same function skips the same way for the same reason.
        assertEq(vc.unverifiedForTest(), 1, "an unforked run records the check as UNVERIFIED");
        ProjectScratch.clean(SEL_UNFORKED);
    }

    /// A chain with no project store yet is a bootstrap state, not a fault.
    function test_NoProjectStore_Silent() public {
        (uint256 fails, uint256 warns) = new VerifyChain().failCodelessDeploymentsForTest(SEL_NOSTORE, true);
        assertEq(fails, 0, "no store is not a failure");
        assertEq(warns, 0, "and not a warning");
    }

    /// The blind spot in its narrowest form: a named entry that is NOT an active pointer. Both active
    /// pointers hold code, so the pre-existing checks are satisfied and only this rung can catch it.
    function test_NamedEntryNotActive_StillFails() public {
        _writeStore(
            SEL_NAMEDONLY,
            string.concat(
                '{"BnM-T_Token":"',
                vm.toString(TOKEN),
                '","OLD-T_BurnMintTokenPool_2.0.0":"',
                vm.toString(LOCKBOX),
                '"}'
            )
        );
        vm.etch(TOKEN, SOME_CODE);
        vm.etch(POOL, SOME_CODE);
        (uint256 fails,) = new VerifyChain().failCodelessDeploymentsForTest(SEL_NAMEDONLY, true);
        assertEq(fails, 1, "the codeless named entry must be named even though it is not an active pointer");
        ProjectScratch.clean(SEL_NAMEDONLY);
    }

    /// The check is WIRED into the registry rung, not merely present: deleting the call from
    /// `_checkRegistryAndExtras` left every test above green. Both active pointers hold code so the
    /// pre-existing checks cannot contribute a FAIL, leaving the lock box as the only possible source.
    function test_WiredIntoTheRegistryRung() public {
        _writeFullStore(SEL_WIRED);
        vm.etch(TOKEN, SOME_CODE);
        vm.etch(POOL, SOME_CODE);
        vm.etch(HOOKS, SOME_CODE);
        // LOCKBOX deliberately left codeless.
        string memory configJson = '{"explorerUrl":"https://example.invalid","nativeCurrencySymbol":"ETH","ccip":{}}';
        (uint256 fails,) = new VerifyChain().checkRegistryAndExtrasForTest(SEL_WIRED, configJson, true);
        assertGt(fails, 0, "the registry rung must surface the codeless lock box");
        ProjectScratch.clean(SEL_WIRED);
    }

    /// A `deployments` value that is not a string used to abort the whole rung: `_readDeployment` calls
    /// `parseJsonString` inside a `try` success block, where a revert is not routed to the catch, so it
    /// escaped a reader documented as never reverting. The doctor lost its verdict on a store one hand
    /// edit away from valid.
    function test_NonStringDeploymentValue_DoesNotAbortTheRung() public {
        _writeStore(SEL_BADVALUE, string.concat('{"BnM-T_Token":{"addr":"', vm.toString(TOKEN), '"}}'));
        vm.etch(TOKEN, SOME_CODE);
        vm.etch(POOL, SOME_CODE);
        (uint256 fails, uint256 warns) = new VerifyChain().failCodelessDeploymentsForTest(SEL_BADVALUE, true);
        assertEq(fails, 0, "an unreadable value is not a codeless artifact");
        assertEq(warns, 0, "and not a warning from this rung");
        ProjectScratch.clean(SEL_BADVALUE);
    }

    /// `deployments` as an array, not an object. `parseJsonKeys` aborts on it, and this rung runs
    /// before the verdict, so an unguarded call killed the whole doctor on a store one hand edit from
    /// valid.
    function test_DeploymentsWrongShape_DoesNotAbortTheRung() public {
        vm.writeFile(
            ProjectStore._path(SEL_BADSHAPE),
            '{"addresses":{"active":{},"deployments":[]},"lanes":{},"roles":{},"schema":3}'
        );
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.failCodelessDeploymentsForTest(SEL_BADSHAPE, true);
        assertEq(fails, 0, "an unreadable shape is not a codeless artifact");
        assertEq(warns, 0, "and not a warning from this rung");
        assertEq(vc.unverifiedForTest(), 1, "but the store was not checked, and that is recorded");
        ProjectScratch.clean(SEL_BADSHAPE);
    }

    /// The store exists but cannot be OPENED - a different branch from the unparseable-JSON cases
    /// above, which get as far as a parse. Driven with a directory at the store's path: `vm.exists`
    /// answers true and `vm.readFile` reverts, which is what a permissions change or a path collision
    /// looks like to the rung. Left untested, this branch could return in silence and the doctor would
    /// report a clean chain for a store it never opened.
    function test_UnopenableStore_IsRecordedNotSwallowed() public {
        string memory storePath = ProjectStore._path(SEL_NOREAD);
        vm.createDir(storePath, true);
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.failCodelessDeploymentsForTest(SEL_NOREAD, true);
        assertEq(fails, 0, "a store that cannot be opened is not evidence of a codeless artifact");
        assertEq(warns, 0, "and not a warning from this rung");
        assertEq(vc.unverifiedForTest(), 1, "but the check did not run, and the operator is told so");
        vm.removeDir(storePath, true);
    }

    /// A file caught mid-write by a parallel suite. `RegistryWriter._readProjectJson` documents that
    /// this must never revert; the rung has to hold the same line.
    function test_TruncatedStore_DoesNotAbortTheRung() public {
        vm.writeFile(ProjectStore._path(SEL_TRUNC), '{"addresses":{"active":{},"deploy');
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.failCodelessDeploymentsForTest(SEL_TRUNC, true);
        assertEq(fails, 0, "a half-written file is not a codeless artifact");
        assertEq(warns, 0, "and not a warning from this rung");
        assertEq(vc.unverifiedForTest(), 1, "but the store was not checked, and that is recorded");
        ProjectScratch.clean(SEL_TRUNC);
    }

    /// The `active{}` reader got the same fix as the `deployments{}` one, and had no test. Deleting
    /// its inner try/catch left the suite green, which is how the first half of that fix shipped
    /// alone once already.
    function test_NonStringActiveValue_ReadsAsAbsent() public {
        vm.writeFile(
            ProjectStore._path(SEL_BADACTIVE),
            string.concat(
                '{"addresses":{"active":{"token":{"addr":"0x1"}},"deployments":{"BnM-T_Token":"',
                vm.toString(TOKEN),
                '"}},"lanes":{},"roles":{},"schema":3}'
            )
        );
        assertEq(RegistryWriter._read(SEL_BADACTIVE, "token"), address(0), "a non-string active value reads as absent");
        // The store DOES hold a deployments entry, so `fails == 0` is earned by the entry having
        // code - not unreachable-by-construction the way an empty `deployments{}` would make it.
        vm.etch(TOKEN, SOME_CODE);
        (uint256 fails,) = new VerifyChain().failCodelessDeploymentsForTest(SEL_BADACTIVE, true);
        assertEq(fails, 0, "a readable, code-bearing entry FAILs nothing even beside a bad active value");
        ProjectScratch.clean(SEL_BADACTIVE);
    }

    /// The same hardening went into `_warnMultiPoolAmbiguity`, which reads the same store with the same
    /// cheatcodes. Only the sibling rung had a malformed-store test, so this one's guard was untested.
    function test_MultiPoolRung_SurvivesAMalformedStore() public {
        vm.writeFile(
            ProjectStore._path(SEL_MULTIPOOL),
            '{"addresses":{"active":{},"deployments":[]},"lanes":{},"roles":{},"schema":3}'
        );
        (uint256 fails, uint256 warns) = new VerifyChain().warnMultiPoolAmbiguityForTest(SEL_MULTIPOOL);
        assertEq(fails, 0, "an unreadable store is not a multi-pool ambiguity");
        assertEq(warns, 0, "and not a warning");
        ProjectScratch.clean(SEL_MULTIPOOL);
    }

    /// The skip covers BOTH active pointers. Only the token half was exercised, so the pool half could
    /// have been dropped and the doctor would have double-reported the pool with nothing to catch it.
    function test_ActivePoolEntry_IsLeftToThePointerRung() public {
        _writeStore(
            SEL_ACTIVEPOOL,
            string.concat(
                '{"BnM-T_BurnMintTokenPool_2.0.0":"',
                vm.toString(POOL),
                '","BnM-T_LockBox":"',
                vm.toString(LOCKBOX),
                '"}'
            )
        );
        vm.etch(TOKEN, SOME_CODE);
        // POOL and LOCKBOX both codeless: only the lock box may be named here.
        (uint256 fails,) = new VerifyChain().failCodelessDeploymentsForTest(SEL_ACTIVEPOOL, true);
        assertEq(fails, 1, "the active pool entry belongs to the pointer rung, the lock box to this one");
        ProjectScratch.clean(SEL_ACTIVEPOOL);
    }
}
