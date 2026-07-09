// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {DeployAdvancedPoolHooks} from "../../script/configure/allowlist/DeployAdvancedPoolHooks.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork parity tests for the PR 1.2 rollout of the `allowlist/` and `authorized-callers/` write
/// scripts. Hooks are deployed from the repo's own `DeployAdvancedPoolHooks` script (driven by
/// `script/input/advanced-pool-hooks.json`, with the allowlist overridden via the `ALLOWLIST` env var);
/// allowlist and authorized-caller state changes are exercised through the `CctActions` builders and
/// asserted via `getAllowList` / `checkAllowList` / `getAllAuthorizedCallers`.
contract HooksActionsForkTest is BaseForkTest {
    // A FIXED allowlist value shared by every test that runs the deploy script. `vm.setEnv` is process-wide,
    // so keeping the value identical across suites makes the deploy deterministic under parallel runs.
    address internal constant ALLOWED = address(0x00000000000000000000000000000000000000A1);

    address internal token;
    address internal pool;
    address internal owner;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        owner = _scriptBroadcaster();
    }

    /// @dev Runs the repo's DeployAdvancedPoolHooks script with a non-empty allowlist (ALLOWLIST env
    ///      override) and returns the deployed hooks address, recovered from the broadcaster's CREATE
    ///      nonce (the deployment file the script writes is racy under parallel suites).
    function _deployHooksWithAllowlist(address allowed) internal returns (AdvancedPoolHooks hooks) {
        vm.setEnv("ALLOWLIST", vm.toString(allowed));
        uint256 nonceBefore = vm.getNonce(owner);
        new DeployAdvancedPoolHooks().run();
        hooks = AdvancedPoolHooks(vm.computeCreateAddress(owner, nonceBefore));
        assertGt(address(hooks).code.length, 0, "hooks not deployed at computed address");
    }

    function _isAllowListed(AdvancedPoolHooks hooks, address who) internal view returns (bool) {
        try hooks.checkAllowList(who) {
            return true;
        } catch {
            return false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Allowlist: deploy with a non-empty allowlist, connect to the pool, assert getters
    // ─────────────────────────────────────────────────────────────────────────

    function test_Hooks_DeployConnectAndAllowList() public {
        AdvancedPoolHooks hooks = _deployHooksWithAllowlist(ALLOWED);

        // Deployed with a non-empty allowlist => allowlisting is enabled and ALLOWED is on the list.
        assertTrue(hooks.getAllowListEnabled(), "allowlist enabled");
        address[] memory list = hooks.getAllowList();
        assertEq(list.length, 1, "one allowlisted address");
        assertEq(list[0], ALLOWED, "ALLOWED is on the list");
        assertTrue(_isAllowListed(hooks, ALLOWED), "ALLOWED passes checkAllowList");
        assertFalse(_isAllowListed(hooks, address(0xDEAD)), "a stranger fails checkAllowList");

        // Connect the hooks to the fixture pool through the action layer.
        _exec(owner, CctActions.updateAdvancedPoolHooks(pool, address(hooks)));

        // Add + remove an allowlisted address through the action layer.
        address newAllowed = address(0xB2);
        address[] memory adds = new address[](1);
        adds[0] = newAllowed;
        _exec(owner, CctActions.applyAllowListUpdates(address(hooks), new address[](0), adds));
        assertTrue(_isAllowListed(hooks, newAllowed), "newAllowed added");
        assertEq(hooks.getAllowList().length, 2, "list grew to two");

        address[] memory removes = new address[](1);
        removes[0] = newAllowed;
        _exec(owner, CctActions.applyAllowListUpdates(address(hooks), removes, new address[](0)));
        assertFalse(_isAllowListed(hooks, newAllowed), "newAllowed removed");
        assertEq(hooks.getAllowList().length, 1, "list back to one");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Immutability trap: allowlistEnabled is fixed at deploy from whether the initial allowlist is empty.
    // Enabling allowlisting later needs a NEW hooks contract — applyAllowListUpdates reverts on a
    // hooks deployed with an empty allowlist (AllowListNotEnabled).
    // ─────────────────────────────────────────────────────────────────────────

    function test_Hooks_ImmutabilityTrap_EmptyAllowlistCannotEnableLater() public {
        // Empty allowlist at construction => allowlisting is permanently disabled on this instance.
        AdvancedPoolHooks emptyHooks = new AdvancedPoolHooks(new address[](0), 0, address(0), new address[](0));
        assertFalse(emptyHooks.getAllowListEnabled(), "empty-allowlist hooks: allowlisting disabled");

        address[] memory adds = new address[](1);
        adds[0] = ALLOWED;
        // Trying to add later reverts — the only fix is to deploy a NEW hooks contract with a non-empty list.
        vm.prank(emptyHooks.owner());
        (bool ok, bytes memory ret) =
            address(emptyHooks).call(abi.encodeCall(AdvancedPoolHooks.applyAllowListUpdates, (new address[](0), adds)));
        assertFalse(ok, "cannot enable allowlisting after an empty deploy");
        assertEq(bytes4(ret), AdvancedPoolHooks.AllowListNotEnabled.selector, "AllowListNotEnabled");

        // A fresh hooks deployed WITH a non-empty allowlist is enabled — the trap's escape hatch.
        AdvancedPoolHooks enabledHooks = _deployHooksWithAllowlist(ALLOWED);
        assertTrue(enabledHooks.getAllowListEnabled(), "new hooks with non-empty allowlist: enabled");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Authorized callers (ERC20LockBox variant): add then remove, asserted via getAllAuthorizedCallers
    // ─────────────────────────────────────────────────────────────────────────

    function test_LockBox_AuthorizedCallerUpdates() public {
        ERC20LockBox lockBox = new ERC20LockBox(token); // deployed by this test => owner is this contract
        assertEq(lockBox.getAllAuthorizedCallers().length, 0, "no callers initially");

        address caller = address(0xCA11E4);
        address[] memory adds = new address[](1);
        adds[0] = caller;
        _exec(address(this), CctActions.applyAuthorizedCallerUpdates(address(lockBox), adds, new address[](0)));

        address[] memory after1 = lockBox.getAllAuthorizedCallers();
        assertEq(after1.length, 1, "caller added");
        assertEq(after1[0], caller, "caller is the one added");

        address[] memory removes = new address[](1);
        removes[0] = caller;
        _exec(address(this), CctActions.applyAuthorizedCallerUpdates(address(lockBox), new address[](0), removes));
        assertEq(lockBox.getAllAuthorizedCallers().length, 0, "caller removed");
    }
}
