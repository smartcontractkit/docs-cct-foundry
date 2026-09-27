// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {
    MockPolicyEngine,
    MockPolicyEngineRevertingDetach
} from "@chainlink/contracts-ccip/contracts/test/mocks/MockPolicyEngine.sol";
import {PolicyEngine} from "@chainlink/policy-management/core/PolicyEngine.sol";
import {VolumePolicy} from "@chainlink/policy-management/policies/VolumePolicy.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";
import {IExtractor} from "@chainlink/policy-management/interfaces/IExtractor.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/interfaces/IAdvancedPoolHooks.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {DeployAdvancedPoolHooks} from "../../script/configure/allowlist/DeployAdvancedPoolHooks.s.sol";
import {SetPolicyEngine} from "../../script/configure/policy-engine/SetPolicyEngine.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @dev Test-local extractor: yields the postflightCheck localAmount as the "amount" parameter, the
///      shape the Platform's built-in CCIP extractor provides for these selectors.
contract PostflightAmountExtractor is IExtractor {
    bytes32 public constant PARAM_AMOUNT = keccak256("amount");

    function typeAndVersion() external pure returns (string memory) {
        return "PostflightAmountExtractor 1.0.0";
    }

    function extract(IPolicyEngine.Payload calldata payload) external pure returns (IPolicyEngine.Parameter[] memory) {
        (, uint256 localAmount,) = abi.decode(payload.data, (Pool.ReleaseOrMintInV1, uint256, bytes4));
        IPolicyEngine.Parameter[] memory result = new IPolicyEngine.Parameter[](1);
        result[0] = IPolicyEngine.Parameter(PARAM_AMOUNT, abi.encode(localAmount));
        return result;
    }
}

/// @title PolicyEngineReviewFixes
/// @notice Validates the fixes for review findings F2, F3 and F4 through the SetPolicyEngine script
///         harness (`runWith`, the parameterised entrypoint that bypasses the process-wide env) and
///         the new `_setPolicyEngineAllowFailedDetach` builder. The findings themselves are proven
///         in PolicyEngineReviewProofs.t.sol.
contract PolicyEngineReviewFixesForkTest is BaseForkTest {
    // A FIXED allowlist value shared by every test that runs the deploy script (vm.setEnv is
    // process-wide, so an identical value keeps the deploy deterministic under parallel suites).
    address internal constant ALLOWED = address(0x00000000000000000000000000000000000000A1);

    address internal owner;

    function setUp() public override {
        super.setUp();
        owner = _scriptBroadcaster();
    }

    /// @dev Deploys hooks through the repo's deploy script with the shared fixed allowlist and the
    ///      engine pinned to zero (the same race-avoidance pins PolicyEngineActionsForkTest uses).
    function _deployHooks() internal returns (AdvancedPoolHooks hooks) {
        vm.setEnv("ALLOWLIST", vm.toString(ALLOWED));
        vm.setEnv("POLICY_ENGINE", vm.toString(address(0)));
        uint256 nonceBefore = vm.getNonce(owner);
        new DeployAdvancedPoolHooks().run();
        hooks = AdvancedPoolHooks(vm.computeCreateAddress(owner, nonceBefore));
        assertGt(address(hooks).code.length, 0, "hooks not deployed at computed address");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F2 fix: the pre-broadcast refusals (codeless engine, same address)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A codeless POLICY_ENGINE is refused before broadcasting, with a named reason instead of
    ///      the empty-data revert the hook would produce.
    function test_F2_fix_refusesCodelessEngine() public {
        AdvancedPoolHooks hooks = _deployHooks();
        address eoa = makeAddr("codeless-engine");
        SetPolicyEngine script = new SetPolicyEngine();
        vm.expectRevert(
            bytes(
                string.concat(
                    "POLICY_ENGINE ",
                    vm.toString(eoa),
                    " has no code on this chain. Pass the Policy Engine deployed on this chain, or 0x0 to disconnect."
                )
            )
        );
        script.runWith(address(hooks), eoa, false);
    }

    /// @dev A deployed engine and the zero address both pass the pre-broadcast checks.
    function test_F2_fix_acceptsDeployedEngineAndZero() public {
        AdvancedPoolHooks hooks = _deployHooks();
        MockPolicyEngine engine = new MockPolicyEngine();
        SetPolicyEngine script = new SetPolicyEngine();

        script.runWith(address(hooks), address(engine), false);
        assertEq(hooks.getPolicyEngine(), address(engine), "a deployed engine is accepted");

        script.runWith(address(hooks), address(0), false);
        assertEq(hooks.getPolicyEngine(), address(0), "the zero address is accepted (disconnect)");
    }

    /// @dev A same-address update is still refused (the pre-existing check, unchanged by the fix).
    function test_F2_fix_stillRefusesSameAddress() public {
        AdvancedPoolHooks hooks = _deployHooks();
        MockPolicyEngine engine = new MockPolicyEngine();
        SetPolicyEngine script = new SetPolicyEngine();

        script.runWith(address(hooks), address(engine), false);

        vm.expectRevert(
            bytes(
                string.concat(
                    "POLICY_ENGINE equals the current engine (",
                    vm.toString(address(engine)),
                    "). setPolicyEngine would be a no-op. Pass a different address."
                )
            )
        );
        script.runWith(address(hooks), address(engine), false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F3 fix: provision, then swap (the order the doc recommends)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Provisioning the new engine BEFORE the hook attaches works: setExtractor,
    ///      addPolicy(<hooks>, ...) and setTargetDefaultPolicyAllow(<hooks>, true) all succeed on a
    ///      not-yet-attached target, and after the swap a within-limits amount passes while an
    ///      over-limit amount reverts PolicyRunRejected.
    function test_F3_fix_provisionThenSwap() public {
        AdvancedPoolHooks hooks = _deployHooks();
        PolicyEngine engine = PolicyEngine(Clones.clone(address(new PolicyEngine())));
        engine.initialize(false, address(this));

        // Provision for the hooks address BEFORE the hook attaches.
        engine.setExtractor(AdvancedPoolHooks.postflightCheck.selector, address(new PostflightAmountExtractor()));
        VolumePolicy policy = VolumePolicy(Clones.clone(address(new VolumePolicy())));
        policy.initialize(address(engine), address(this), abi.encode(0, 100));
        bytes32[] memory names = new bytes32[](1);
        names[0] = keccak256("amount");
        engine.addPolicy(address(hooks), AdvancedPoolHooks.postflightCheck.selector, address(policy), names);
        engine.setTargetDefaultPolicyAllow(address(hooks), true);

        // The test contract stands in for the pool as the postflightCheck caller.
        address[] memory adds = new address[](1);
        adds[0] = address(this);
        vm.prank(hooks.owner());
        AuthorizedCallers(address(hooks))
            .applyAuthorizedCallerUpdates(
                AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: new address[](0)})
            );

        // Swap: the provisioned engine accepts 50 and rejects 500.
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));
        Pool.ReleaseOrMintInV1 memory in_ = _releaseOrMintIn();

        vm.prank(address(this));
        hooks.postflightCheck(in_, 50, bytes4(0));

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.PolicyRunRejected.selector,
                address(policy),
                "amount outside allowed volume limits",
                _postflightPayload(500)
            )
        );
        hooks.postflightCheck(in_, 500, bytes4(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F4 fix: the ALLOW_FAILED_DETACH switch and its builder
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The builder encodes setPolicyEngineAllowFailedDetach exactly, and executing it against an
    ///      engine whose detach() reverts emits PolicyEngineDetachFailed(bad, DetachNotSupported())
    ///      and attaches the new engine.
    function test_F4_fix_allowFailedDetachBuilder() public {
        AdvancedPoolHooks hooks = _deployHooks();
        MockPolicyEngineRevertingDetach bad = new MockPolicyEngineRevertingDetach();
        MockPolicyEngine good = new MockPolicyEngine();

        CctActions.Call[] memory calls = CctActions._setPolicyEngineAllowFailedDetach(address(hooks), address(good));
        assertEq(calls.length, 1, "one call");
        assertEq(
            bytes4(calls[0].data),
            AdvancedPoolHooks.setPolicyEngineAllowFailedDetach.selector,
            "setPolicyEngineAllowFailedDetach selector"
        );

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(bad)));
        vm.expectEmit(true, false, false, true);
        emit AdvancedPoolHooks.PolicyEngineDetachFailed(address(bad), abi.encodeWithSignature("DetachNotSupported()"));
        _exec(owner, calls);
        assertEq(hooks.getPolicyEngine(), address(good), "the new engine is attached");
        assertTrue(good.isAttached(address(hooks)), "the new engine records the hook as attached");
    }

    /// @dev The script's ALLOW_FAILED_DETACH=true switch routes to the allow-failed-detach builder:
    ///      with a reverting old engine, the run completes and the new engine lands.
    function test_F4_fix_scriptSwitchRoutesToAllowFailedDetach() public {
        AdvancedPoolHooks hooks = _deployHooks();
        MockPolicyEngineRevertingDetach bad = new MockPolicyEngineRevertingDetach();
        MockPolicyEngine good = new MockPolicyEngine();

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(bad)));

        SetPolicyEngine script = new SetPolicyEngine();
        script.runWith(address(hooks), address(good), true);
        assertEq(hooks.getPolicyEngine(), address(good), "the switch must land the new engine");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A minimal inbound payload for a direct postflightCheck call, as the pool would make from
    ///      inside releaseOrMint.
    function _releaseOrMintIn() internal pure returns (Pool.ReleaseOrMintInV1 memory) {
        return Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(address(0xB0B)),
            remoteChainSelector: 8236463271206331221,
            receiver: address(0xB0B),
            sourceDenominatedAmount: 1e18,
            localToken: address(0),
            sourcePoolAddress: abi.encode(address(0x1111111111111111111111111111111111111111)),
            sourcePoolData: abi.encode(uint256(18)),
            offchainTokenData: ""
        });
    }

    /// @dev The exact Payload the hook builds for postflightCheck with the given localAmount, for
    ///      the expectRevert equality check.
    function _postflightPayload(uint256 localAmount) internal view returns (IPolicyEngine.Payload memory) {
        bytes memory full =
            abi.encodeCall(IAdvancedPoolHooks.postflightCheck, (_releaseOrMintIn(), localAmount, bytes4(0)));
        bytes memory stripped = new bytes(full.length - 4);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = full[i + 4];
        }
        return IPolicyEngine.Payload({
            selector: AdvancedPoolHooks.postflightCheck.selector, sender: address(this), data: stripped, context: ""
        });
    }
}
