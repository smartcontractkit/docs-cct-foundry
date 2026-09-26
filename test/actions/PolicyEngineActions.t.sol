// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {MockPolicyEngine} from "@chainlink/contracts-ccip/contracts/test/mocks/MockPolicyEngine.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {DeployAdvancedPoolHooks} from "../../script/configure/allowlist/DeployAdvancedPoolHooks.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork parity tests for the policy-engine action layer. Hooks are deployed from the
///         repo's own `DeployAdvancedPoolHooks` script (driven by `script/input/advanced-pool-hooks.json`,
///         with the allowlist overridden via the `ALLOWLIST` env var); engine changes are exercised
///         through the `CctActions` builder and asserted via `getPolicyEngine` plus the mock
///         engine's own attached-target view.
/// @dev Engine writes go through the action layer (`_exec`), not the `SetPolicyEngine` script's
///      env interface: `vm.setEnv` writes the whole forge PROCESS environment and forge runs
///      suites in parallel, so a `POOL_HOOKS` set here races every other suite's fixture pins
///      (see the note above `BaseForkTest.deployTokenAndPoolFixture`). The script itself is a thin
///      wrapper over the same builder, so exercising the builder proves the script's calldata.
contract PolicyEngineActionsForkTest is BaseForkTest {
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
    ///      nonce (the deployment file the script writes is racy under parallel suites). `POLICY_ENGINE`
    ///      is pinned to the zero address for the same reason `deployTokenAndPoolFixture` pins
    ///      `POOL_HOOKS`: a value left in the process environment by an earlier test would wire the
    ///      fresh hooks to a stale engine address.
    function _deployHooks(address allowed) internal returns (AdvancedPoolHooks hooks) {
        vm.setEnv("ALLOWLIST", vm.toString(allowed));
        vm.setEnv("POLICY_ENGINE", vm.toString(address(0)));
        uint256 nonceBefore = vm.getNonce(owner);
        new DeployAdvancedPoolHooks().run();
        hooks = AdvancedPoolHooks(vm.computeCreateAddress(owner, nonceBefore));
        assertGt(address(hooks).code.length, 0, "hooks not deployed at computed address");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // setPolicyEngine: attach, swap, disconnect, asserted via getPolicyEngine + the mock's view
    // ─────────────────────────────────────────────────────────────────────────

    function test_PolicyEngine_SetSwapAndDisconnect() public {
        AdvancedPoolHooks hooks = _deployHooks(ALLOWED);
        MockPolicyEngine engine1 = new MockPolicyEngine();
        MockPolicyEngine engine2 = new MockPolicyEngine();

        // No engine initially.
        assertEq(hooks.getPolicyEngine(), address(0), "no engine initially");

        // Attach: the hook calls attach() on the engine, so the engine records it as a target.
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine1)));
        assertEq(hooks.getPolicyEngine(), address(engine1), "engine1 set");
        assertTrue(engine1.isAttached(address(hooks)), "engine1 records the hook as attached");

        // Swap: the hook detaches engine1 and attaches engine2.
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine2)));
        assertEq(hooks.getPolicyEngine(), address(engine2), "engine2 set");
        assertFalse(engine1.isAttached(address(hooks)), "engine1 detached");
        assertTrue(engine2.isAttached(address(hooks)), "engine2 records the hook as attached");

        // Disconnect: the zero address detaches engine2 and stops policy checks.
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(0)));
        assertEq(hooks.getPolicyEngine(), address(0), "engine disconnected");
        assertFalse(engine2.isAttached(address(hooks)), "engine2 detached");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Same-address no-op: the hook returns without a transaction; the state is unchanged.
    // ─────────────────────────────────────────────────────────────────────────

    function test_PolicyEngine_SameAddressIsNoOp() public {
        AdvancedPoolHooks hooks = _deployHooks(ALLOWED);
        MockPolicyEngine engine = new MockPolicyEngine();

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));
        assertEq(hooks.getPolicyEngine(), address(engine), "engine set");

        // Setting the same address again changes nothing: no detach, no attach, no event.
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));
        assertEq(hooks.getPolicyEngine(), address(engine), "engine unchanged");
        assertTrue(engine.isAttached(address(hooks)), "engine still attached");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Action-layer parity: the builder encodes the exact selector the script hands the executor.
    // ─────────────────────────────────────────────────────────────────────────

    function test_PolicyEngine_ActionBuilderMatchesSelector() public {
        AdvancedPoolHooks hooks = _deployHooks(ALLOWED);
        MockPolicyEngine engine = new MockPolicyEngine();

        CctActions.Call[] memory set = CctActions._setPolicyEngine(address(hooks), address(engine));
        assertEq(set.length, 1, "one call");
        assertEq(set[0].target, address(hooks), "targets the hooks");
        assertEq(bytes4(set[0].data), AdvancedPoolHooks.setPolicyEngine.selector, "setPolicyEngine selector");
    }
}
