// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/interfaces/IAdvancedPoolHooks.sol";
import {
    MockPolicyEngine,
    MockPolicyEngineRevertingDetach
} from "@chainlink/contracts-ccip/contracts/test/mocks/MockPolicyEngine.sol";
import {PolicyEngine} from "@chainlink/policy-management/core/PolicyEngine.sol";
import {VolumePolicy} from "@chainlink/policy-management/policies/VolumePolicy.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";
import {IExtractor} from "@chainlink/policy-management/interfaces/IExtractor.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {DeployAdvancedPoolHooks} from "../../script/configure/allowlist/DeployAdvancedPoolHooks.s.sol";
import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
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

/// @title PolicyEngineReviewProofs
/// @notice Review findings F1-F4 and F6, each proven against the real AdvancedPoolHooks bytecode and
///         (where the finding is about engine behavior) the real ACE 1.0.0 PolicyEngine and
///         VolumePolicy, not the mock. The fixes are validated in PolicyEngineReviewFixes.t.sol.
contract PolicyEngineReviewProofsForkTest is BaseForkTest {
    // A FIXED allowlist value shared by every test that runs the deploy script (vm.setEnv is
    // process-wide, so an identical value keeps the deploy deterministic under parallel suites).
    address internal constant ALLOWED = address(0x00000000000000000000000000000000000000A1);

    // The FeeQuoter default destGasOverhead a source pool quotes when no lane fee config is set.
    uint32 internal constant DEFAULT_DEST_GAS_OVERHEAD = 90_000;

    address internal owner;
    RolesSnapshot internal snap;
    RolesAuditor internal auditor;

    function setUp() public override {
        super.setUp();
        owner = _scriptBroadcaster();
        snap = new RolesSnapshot();
        auditor = new RolesAuditor();
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

    /// @dev Deploys the REAL ACE 1.0.0 engine as a minimal proxy (the implementation's constructor
    ///      disables initializers, so initialize must run on a clone) with the given default posture.
    function _deployRealEngine(bool defaultAllow) internal returns (PolicyEngine engine) {
        PolicyEngine impl = new PolicyEngine();
        engine = PolicyEngine(Clones.clone(address(impl)));
        engine.initialize(defaultAllow, address(this));
    }

    /// @dev Provisions the engine for the hooks' postflightCheck: an extractor that yields the
    ///      localAmount as "amount", a VolumePolicy bound to (min, max), and the policy registered
    ///      for the hooks address on the postflightCheck selector, mapped to "amount".
    function _provisionVolumePolicy(PolicyEngine engine, address hooks, uint256 min, uint256 max) internal {
        engine.setExtractor(AdvancedPoolHooks.postflightCheck.selector, address(new PostflightAmountExtractor()));
        VolumePolicy policy = VolumePolicy(Clones.clone(address(new VolumePolicy())));
        policy.initialize(address(engine), address(this), abi.encode(min, max));
        bytes32[] memory names = new bytes32[](1);
        names[0] = keccak256("amount");
        engine.addPolicy(hooks, AdvancedPoolHooks.postflightCheck.selector, address(policy), names);
    }

    /// @dev The compiled hooks gate preflightCheck/postflightCheck on the authorized-caller set
    ///      unconditionally, so a test driving postflightCheck directly must first authorize itself
    ///      (the pool would be the caller in production; here the test stands in for it).
    function _authorizeSelf(AdvancedPoolHooks hooks) internal {
        address[] memory adds = new address[](1);
        adds[0] = address(this);
        vm.prank(hooks.owner());
        AuthorizedCallers(address(hooks))
            .applyAuthorizedCallerUpdates(
                AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: new address[](0)})
            );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F1: after SetPolicyEngine, the declared roles{} is stale until re-snapshotted
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev hooks.policyEngine is a governance-critical roles{} field (RolesAuditor._auditHooks).
    ///      Attach the hooks to the fixture pool, snapshot roles{} with no engine, move the engine
    ///      through the action layer, and the STALE declaration must FAIL the audit naming
    ///      hooks.policyEngine - the drift the roles runbook says to treat as a potential
    ///      compromise. A fresh RolesSnapshot.build (what make snapshot-chain runs) clears it.
    function test_F1_setPolicyEngineDriftsDeclaredRoles() public {
        (, address pool) = deployTokenAndPoolFixture();
        AdvancedPoolHooks hooks = _deployHooks();
        _exec(owner, CctActions._updateAdvancedPoolHooks(pool, address(hooks)));
        MockPolicyEngine engine = new MockPolicyEngine();

        string memory baseJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
        string memory projectJson = _fixtureProjectJson(pool);
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson, projectJson);
        assertTrue(
            vm.keyExistsJson(roles, ".hooks.policyEngine"), "precondition: the snapshot declares hooks.policyEngine"
        );
        RolesAuditor.Result memory clean = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(clean.fails, 0, "precondition: the engine-less declaration reconciles clean");

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));

        RolesAuditor.Result memory stale = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertGt(stale.fails, 0, "the stale declaration must FAIL after the engine moved");
        assertTrue(vm.contains(stale.failedFields, "hooks.policyEngine"), "the FAIL must name hooks.policyEngine");

        // The named remedy: a fresh build (what make snapshot-chain runs) records the new engine.
        string memory fresh = snap.build("ethereum-testnet-sepolia", baseJson, projectJson);
        assertEq(
            vm.parseJsonAddress(fresh, ".hooks.policyEngine"),
            address(engine),
            "a fresh snapshot must record the new engine"
        );
        RolesAuditor.Result memory reconciled = auditor.auditJson("ethereum-testnet-sepolia", _wrap(fresh));
        assertEq(reconciled.fails, 0, "the re-snapshotted declaration must reconcile clean");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F2: a codeless POLICY_ENGINE reverts with empty data
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev attach() returns nothing, so the hook's call to a codeless address (an EOA or a mistyped
    ///      engine) reverts with no selector and no reason string.
    function test_F2_codelessEngineRevertsWithEmptyData() public {
        AdvancedPoolHooks hooks = _deployHooks();
        address eoa = makeAddr("codeless-engine");
        vm.expectRevert(bytes(""));
        _exec(owner, CctActions._setPolicyEngine(address(hooks), eoa));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F3: an unprovisioned engine rejects every transfer from the moment the swap lands
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Extractors, policies and the per-target default live on the engine keyed by the hooks
    ///      address; nothing carries over from the old engine. With the ACE default of reject, the
    ///      real 1.0.0 engine rejects the hook's postflightCheck with PolicyRunRejected the moment
    ///      the swap lands.
    function test_F3_proof_unprovisionedEngineRejectsEveryTransfer() public {
        AdvancedPoolHooks hooks = _deployHooks();
        _authorizeSelf(hooks);
        PolicyEngine engine = _deployRealEngine(false);

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));

        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.PolicyRunRejected.selector,
                address(0),
                "no policy allowed the action and default is reject",
                _postflightPayload()
            )
        );
        hooks.postflightCheck(_releaseOrMintIn(), 1e18, bytes4(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F4: a reverting detach() blocks every later setPolicyEngine; the forced path strands the hook
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev With an engine whose detach() reverts, every later setPolicyEngine reverts
    ///      PolicyEngineDetachReverted; only setPolicyEngineAllowFailedDetach moves off it.
    function test_F4_detachRevertBlocksSetPolicyEngine() public {
        AdvancedPoolHooks hooks = _deployHooks();
        MockPolicyEngineRevertingDetach bad = new MockPolicyEngineRevertingDetach();
        MockPolicyEngine good = new MockPolicyEngine();

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(bad)));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AdvancedPoolHooks.PolicyEngineDetachReverted.selector,
                address(bad),
                abi.encodeWithSignature("DetachNotSupported()")
            )
        );
        hooks.setPolicyEngine(address(good));

        _exec(owner, CctActions._setPolicyEngineAllowFailedDetach(address(hooks), address(good)));
        assertEq(hooks.getPolicyEngine(), address(good), "the forced path must move to the new engine");
    }

    /// @dev The old engine keeps the hook listed as attached after a forced move (its detach()
    ///      reverted, so targetAttached stayed true), so pointing back at it reverts
    ///      TargetAlreadyAttached on the real engine's attach(). The reverting detach is forced
    ///      with vm.mockCallRevert so the REAL engine's own attach() tracking produces the revert.
    function test_F4_returningToAForceDetachedEngineReverts() public {
        AdvancedPoolHooks hooks = _deployHooks();
        PolicyEngine bad = _deployRealEngine(true);
        PolicyEngine good = _deployRealEngine(true);

        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(bad)));
        vm.mockCallRevert(
            address(bad),
            abi.encodeWithSelector(IPolicyEngine.detach.selector),
            abi.encodeWithSignature("DetachNotSupported()")
        );
        _exec(owner, CctActions._setPolicyEngineAllowFailedDetach(address(hooks), address(good)));
        vm.clearMockedCalls();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPolicyEngine.TargetAlreadyAttached.selector, address(hooks)));
        hooks.setPolicyEngine(address(bad));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // F6: postflightCheck gas exceeds the 90,000 destGasOverhead default once an engine runs
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev postflightCheck runs inside releaseOrMint on the destination, within the gas the source
    ///      pool quotes as destGasOverhead for that lane. Measures the hook's postflightCheck
    ///      subtree with no engine and with the real engine + one VolumePolicy: one cheap policy
    ///      alone exceeds the 90,000 FeeQuoter default, before the mint itself.
    function test_F6_postflightEngineRunGas() public {
        AdvancedPoolHooks hooks = _deployHooks();
        _authorizeSelf(hooks);
        Pool.ReleaseOrMintInV1 memory in_ = _releaseOrMintIn();

        uint256 noEngineStart = gasleft();
        vm.prank(address(this));
        hooks.postflightCheck(in_, 1e18, bytes4(0));
        uint256 noEngineGas = noEngineStart - gasleft();

        PolicyEngine engine = _deployRealEngine(true);
        _provisionVolumePolicy(engine, address(hooks), 0, 1e18);
        _exec(owner, CctActions._setPolicyEngine(address(hooks), address(engine)));

        uint256 withEngineStart = gasleft();
        vm.prank(address(this));
        hooks.postflightCheck(in_, 1e18, bytes4(0));
        uint256 withEngineGas = withEngineStart - gasleft();

        assertGt(noEngineGas, 0, "sanity: the no-engine run consumed gas");
        assertGt(withEngineGas, noEngineGas, "the engine run must cost more than the no-engine run");
        assertGt(
            withEngineGas,
            DEFAULT_DEST_GAS_OVERHEAD,
            "one VolumePolicy in postflightCheck alone must exceed the 90,000 destGasOverhead default"
        );
        emit log_named_uint("postflightCheck gas without an engine", noEngineGas);
        emit log_named_uint("postflightCheck gas with the real engine + one VolumePolicy", withEngineGas);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The EXPLICIT projectJson a build() resolves the fixture token+pool from (the same
    ///      isolation seam RolesAuthorityTest uses: no process-global env, no real project file).
    function _fixtureProjectJson(address pool) internal returns (string memory) {
        address token = deployTokenFixture();
        return string.concat(
            "{\"roles\":{\"token\":{\"address\":\"",
            vm.toString(token),
            "\"},\"pool\":{\"address\":\"",
            vm.toString(pool),
            "\"}}}"
        );
    }

    function _wrap(string memory rolesJson) internal pure returns (string memory) {
        return string.concat("{\"roles\":", rolesJson, "}");
    }

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

    /// @dev The exact Payload the hook builds for postflightCheck (selector, sender, data minus the
    ///      4-byte prefix, context = offchainTokenData), for the expectRevert equality check.
    function _postflightPayload() internal view returns (IPolicyEngine.Payload memory) {
        bytes memory full = abi.encodeCall(IAdvancedPoolHooks.postflightCheck, (_releaseOrMintIn(), 1e18, bytes4(0)));
        bytes memory stripped = new bytes(full.length - 4);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = full[i + 4];
        }
        return IPolicyEngine.Payload({
            selector: AdvancedPoolHooks.postflightCheck.selector, sender: address(this), data: stripped, context: ""
        });
    }
}
