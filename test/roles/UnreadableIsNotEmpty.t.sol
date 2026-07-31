// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";

/// @dev A contract that has code and answers nothing. Every probe against it fails, which is the shape
///      an operator-supplied hooks contract takes when the audit cannot read it.
contract SilentContract {
    // Deliberately empty: any call reverts, so every probe fails.
    fallback() external {
        revert("silent");
    }
}

/// @notice A field the audit could not read must not reconcile clean.
///
/// The probes return a zero value alongside an `ok` flag, and where a caller drops that flag, a failed
/// read becomes the assertion "the chain holds 0x0 / false / an empty set". A snapshot then writes those
/// zeros into the declaration and the audit compares them against the same failed reads, so the two
/// agree because neither observed anything. The verdict says the declared authority matches the chain
/// while nothing about that contract was established.
contract UnreadableIsNotEmptyTest is BaseForkTest {
    RolesAuditor internal auditor;
    address internal silent;
    address internal fixtureToken;
    address internal fixturePool;

    function setUp() public override {
        super.setUp();
        auditor = new RolesAuditor();
        silent = address(new SilentContract());
        (fixtureToken, fixturePool) = deployTokenAndPoolFixture();
    }

    /// @dev Wrap a built `roles{}` object as a project document the auditor can read.
    function _wrap(string memory rolesJson) private pure returns (string memory) {
        return string.concat("{\"roles\":", rolesJson, "}");
    }

    /// @dev The declaration says the hooks contract holds nothing, which is exactly what the failed
    ///      probes report. Agreement here is an artefact of the read failing, not a fact about the chain.
    function test_HooksThatAnswerNothing_DoNotReconcileClean() public {
        string memory roles = string.concat(
            '{"token":{"address":"',
            vm.toString(fixtureToken),
            '","type":"crosschain"},"pool":{"address":"',
            vm.toString(fixturePool),
            '"},"hooks":{"address":"',
            vm.toString(silent),
            '","owner":"0x0000000000000000000000000000000000000000",',
            '"allowlistEnabled":false,"allowlist":[],"authorizedCallers":[]}}'
        );

        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));

        assertGt(r.fails, 0, "a hooks contract whose every probe failed must FAIL: the audit observed nothing about it");
    }

    /// @dev The same address declared with a NON-zero owner. This is the control: it already fails today,
    ///      which is what makes the test above meaningful rather than a tautology. If the audit reported
    ///      correctly, the two declarations would be distinguishable only by what the chain actually says,
    ///      and here the chain says nothing either way.
    function test_HooksThatAnswerNothing_FailAgainstANonZeroDeclaration() public {
        string memory roles = string.concat(
            '{"token":{"address":"',
            vm.toString(fixtureToken),
            '","type":"crosschain"},"pool":{"address":"',
            vm.toString(fixturePool),
            '"},"hooks":{"address":"',
            vm.toString(silent),
            '","owner":"0x000000000000000000000000000000000000BEEF",',
            '"allowlistEnabled":false,"allowlist":[],"authorizedCallers":[]}}'
        );

        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertGt(r.fails, 0, "a declared owner the chain does not confirm must fail");
    }

    /// @dev The snapshot half of the same contract: a field the chain did not supply is written as
    ///      ABSENT, never as the probe's zero value, and the audit of that snapshot does not pass.
    ///      Writing zeros instead would hand the next audit a declaration built from the same failed
    ///      reads it is about to repeat, and the two would agree about nothing.
    function test_Snapshot_WritesUnreadAsAbsent_AndTheAuditDoesNotPassIt() public {
        string memory prior = string.concat(
            '{"roles":{"token":{"address":"',
            vm.toString(fixtureToken),
            '"},"pool":{"address":"',
            vm.toString(fixturePool),
            '"},"hooks":{"address":"',
            vm.toString(silent),
            '"}}}'
        );
        RolesSnapshot snap = new RolesSnapshot();
        string memory built = _wrap(
            snap.build("ethereum-testnet-sepolia", vm.readFile("config/chains/ethereum-testnet-sepolia.json"), prior)
        );

        assertTrue(vm.keyExistsJson(built, ".roles.hooks.address"), "the anchor address is still recorded");
        assertFalse(vm.keyExistsJson(built, ".roles.hooks.owner"), "an unread owner is not written");
        assertFalse(vm.keyExistsJson(built, ".roles.hooks.allowlistEnabled"), "an unread flag is not written");
        assertFalse(vm.keyExistsJson(built, ".roles.hooks.allowlist"), "an unread allowlist is not written");
        assertFalse(vm.keyExistsJson(built, ".roles.hooks.authorizedCallers"), "an unread caller set is not written");

        assertGt(snap.unreadCount(), 0, "unread fields must be counted so SnapshotChain reports the block PARTIAL");

        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", built);
        assertGt(r.fails, 0, "auditing a snapshot whose hooks answered nothing must not pass");
    }

    /// @dev The complement: a fully readable fixture snapshots with ZERO unread fields, pinning both
    ///      the counter's meaning and its per-build reset.
    function test_Snapshot_ReadableFixture_CountsZeroUnread() public {
        string memory prior = string.concat(
            '{"roles":{"token":{"address":"',
            vm.toString(fixtureToken),
            '"},"pool":{"address":"',
            vm.toString(fixturePool),
            '"}}}'
        );
        RolesSnapshot snap = new RolesSnapshot();
        snap.build("ethereum-testnet-sepolia", vm.readFile("config/chains/ethereum-testnet-sepolia.json"), prior);
        assertEq(snap.unreadCount(), 0, "a fully readable fixture must snapshot with no unread fields");
    }
}
