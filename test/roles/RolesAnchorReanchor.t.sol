// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @dev Pins `REANCHOR=true` through the virtual seam instead of `vm.setEnv`: env vars are
/// process-wide and forge runs suites in parallel, so a real env write would leak sideways.
contract RolesSnapshotReanchoring is RolesSnapshot {
    function _rsReanchor() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Pins `TOKEN`/`TOKEN_POOL` through the same seam, for the no-declaration case.
contract RolesSnapshotEnvOverride is RolesSnapshot {
    function _rsEnvOr(string memory name) internal pure override returns (address) {
        if (keccak256(bytes(name)) == keccak256("TOKEN")) return address(uint160(0xDD01));
        if (keccak256(bytes(name)) == keccak256("TOKEN_POOL")) return address(uint160(0x2102));
        return address(0);
    }
}

/// @title RolesAnchorReanchor
/// @notice The repoint case: replacing a token/pool under one group leaves `roles.*.address` naming the
/// OLD contracts while `addresses.active.*` names the new ones. An anchor that won unconditionally made
/// the `TOKEN`/`TOKEN_POOL` rung and the store rung unreachable the moment a declaration existed, so
/// `snapshot-chain` re-read the same stale anchor, rewrote role holders under it, printed "wrote .roles
/// block" and exited 0 having changed nothing the operator asked for - while `make doctor` prescribed
/// that very command as the remedy.
///
/// These tests pin the two halves of the answer: a stale anchor with no explicit instruction REFUSES (it
/// never silently picks a side), and `REANCHOR=true` RE-ANCHORS (the rung is reachable again). Both
/// assert against `build`'s FIRST step, so they need no fork: resolution runs before any probe.
contract RolesAnchorReanchorTest is Test {
    // Deliberately not the live fixture addresses: this suite asserts resolution, not chain state.
    address internal constant OLD_TOKEN = address(uint160(0xDD01));
    address internal constant OLD_POOL = address(uint160(0x2102));
    address internal constant NEW_TOKEN = address(uint160(0x4F03));
    address internal constant NEW_POOL = address(uint160(0x0404));

    // One scratch store per test. forge runs the functions of a suite in PARALLEL, so a shared
    // selectorName would have them writing and removing each other's file - the sibling
    // `VerifyChainAnchorDrift` suite names its four the same way for the same reason.
    string internal constant CHAIN_STALE = "zz-scratch-anchor-reanchor-stale";
    string internal constant CHAIN_MOVE = "zz-scratch-anchor-reanchor-move";
    string internal constant CHAIN_AGREE = "zz-scratch-anchor-reanchor-agree";
    string internal constant CHAIN_ENV = "zz-scratch-anchor-reanchor-env";

    function setUp() public {
        // Revert-safe sweep BEFORE the body, per the ProjectScratch hard rule.
        ProjectScratch.clean(CHAIN_STALE);
        ProjectScratch.clean(CHAIN_MOVE);
        ProjectScratch.clean(CHAIN_AGREE);
        ProjectScratch.clean(CHAIN_ENV);
    }

    /// @dev A project store whose declaration and active pointers disagree - the post-repoint state.
    function _storeWithRepoint() internal pure returns (string memory) {
        return string.concat(
            '{"addresses":{"active":{"token":"',
            vm.toString(NEW_TOKEN),
            '","tokenPool":"',
            vm.toString(NEW_POOL),
            '"},"deployments":{}},"roles":{"token":{"address":"',
            vm.toString(OLD_TOKEN),
            '"},"pool":{"address":"',
            vm.toString(OLD_POOL),
            '"}},"schema":3}'
        );
    }

    function _writeStore(string memory chain, string memory json) internal {
        vm.writeFile(ProjectScratch.projectPath(chain), json);
    }

    /// The defect case: resolving to OLD_TOKEN and snapshotting it silently. It must refuse instead, and
    /// the message must name BOTH addresses so the operator can act without reading the source.
    function test_StaleAnchor_WithNoOverride_Refuses() public {
        _writeStore(CHAIN_STALE, _storeWithRepoint());
        RolesSnapshot snap = new RolesSnapshot();
        vm.expectRevert(
            bytes(
                string.concat(
                    "[snapshot] STALE ANCHOR: roles.token.address is ",
                    vm.toString(OLD_TOKEN),
                    " but project/",
                    CHAIN_STALE,
                    ".json addresses.active.token is ",
                    vm.toString(NEW_TOKEN),
                    ". Refusing to snapshot: writing role holders under the old address would leave the audit",
                    " reconciling a contract that was replaced. Re-anchor to the deployed one with REANCHOR=true,",
                    " or keep the declaration and point the store back if the repoint was a mistake."
                )
            )
        );
        snap.build(CHAIN_STALE, "{}", _storeWithRepoint());
        ProjectScratch.clean(CHAIN_STALE);
    }

    /// The explicit opt-out: REANCHOR=true moves the anchor to addresses.active.*, and the block it
    /// writes names the DEPLOYED contract - not merely "did not revert".
    function test_Reanchor_MovesAnchorToActive() public {
        _writeStore(CHAIN_MOVE, _storeWithRepoint());
        RolesSnapshot snap = new RolesSnapshotReanchoring();
        string memory rolesJson = snap.build(CHAIN_MOVE, "{}", _storeWithRepoint());
        assertEq(
            vm.parseJsonAddress(rolesJson, ".token.address"),
            NEW_TOKEN,
            "REANCHOR must move roles.token.address to the deployed token"
        );
        assertEq(
            vm.parseJsonAddress(rolesJson, ".pool.address"),
            NEW_POOL,
            "REANCHOR must move roles.pool.address to the deployed pool"
        );
        ProjectScratch.clean(CHAIN_MOVE);
    }

    /// An anchor that still matches the store is untouched - the refusal is scoped to a real divergence,
    /// so an ordinary re-snapshot of an unchanged chain keeps working.
    function test_AnchorMatchingActive_DoesNotRefuse() public {
        string memory json = string.concat(
            '{"addresses":{"active":{"token":"',
            vm.toString(NEW_TOKEN),
            '","tokenPool":"',
            vm.toString(NEW_POOL),
            '"},"deployments":{}},"roles":{"token":{"address":"',
            vm.toString(NEW_TOKEN),
            '"},"pool":{"address":"',
            vm.toString(NEW_POOL),
            '"}},"schema":3}'
        );
        _writeStore(CHAIN_AGREE, json);
        RolesSnapshot snap = new RolesSnapshot();
        string memory rolesJson = snap.build(CHAIN_AGREE, "{}", json);
        assertEq(
            vm.parseJsonAddress(rolesJson, ".token.address"), NEW_TOKEN, "an agreeing anchor is snapshotted unchanged"
        );
        ProjectScratch.clean(CHAIN_AGREE);
    }

    /// The refusal must not spread to the rung it is not about. With no declaration yet, `TOKEN` is the
    /// documented way to snapshot a contract other than the active one - so a `TOKEN` that differs from
    /// `addresses.active.token` is the NORMAL use of the override, not a stale anchor. Policing it here
    /// would kill the flag in the only case it exists for, and would refuse while naming a
    /// `roles.token.address` key the file does not contain.
    function test_EnvOverride_WithNoDeclaration_DoesNotRefuse() public {
        string memory json = string.concat(
            '{"addresses":{"active":{"token":"',
            vm.toString(NEW_TOKEN),
            '","tokenPool":"',
            vm.toString(NEW_POOL),
            '"},"deployments":{}},"schema":3}'
        );
        _writeStore(CHAIN_ENV, json);
        RolesSnapshot snap = new RolesSnapshotEnvOverride();
        string memory rolesJson = snap.build(CHAIN_ENV, "{}", json);
        assertEq(
            vm.parseJsonAddress(rolesJson, ".token.address"),
            OLD_TOKEN,
            "TOKEN must still select its contract when no anchor is declared"
        );
        assertEq(
            vm.parseJsonAddress(rolesJson, ".pool.address"),
            OLD_POOL,
            "TOKEN_POOL must still select its contract when no anchor is declared"
        );
        ProjectScratch.clean(CHAIN_ENV);
    }
}
