// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/contracts/interfaces/IGetCCIPAdmin.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts@5.3.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {AccessControlOnlyToken} from "../fixtures/ClaimPathMocks.sol";
import {ClaimAdmin} from "../../script/setup/ClaimAdmin.s.sol";
import {AcceptAdminRole} from "../../script/setup/AcceptAdminRole.s.sol";
import {SetPool} from "../../script/setup/SetPool.s.sol";
import {TransferOwnership} from "../../script/setup/transfer-ownership/TransferOwnership.s.sol";
import {AcceptOwnership} from "../../script/setup/transfer-ownership/AcceptOwnership.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Parity tests for the action-layer setup scripts.
///
/// Methodology: each test replays the exact typed calls a script makes inline (direct calls from the
/// same signer), snapshots the resulting on-chain state, reverts the fork, then runs the script and
/// asserts the identical end state. Where encoding matters (`applyChainUpdates`, `setPool`), the
/// `CctActions` builder output is additionally pinned against a hand-written `abi.encodeCall`
/// expectation, for an EVM remote AND an SVM remote input.
contract SetupActionsForkTest is BaseForkTest {
    address internal constant NEW_OWNER = address(uint160(uint256(keccak256("setup-actions.new-owner"))));

    // Fixed calldata-parity inputs (EVM remote).
    uint64 internal constant EVM_SELECTOR = 8236463271206331221; // Mantle Sepolia
    address internal constant EVM_REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant EVM_REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);

    // Fixed calldata-parity inputs (SVM remote). Raw 32-byte values derived from an INDEPENDENT
    // base58 decode (Python), not from the code under test.
    uint64 internal constant SVM_SELECTOR = 16423721717087811551; // Solana Devnet
    bytes internal constant SVM_REMOTE_POOL_BYTES =
        hex"276497ba0bb8659172b72edd8c66e18f561764d9c86a610a3a7e0f79c0baf9db";
    bytes internal constant SVM_REMOTE_TOKEN_BYTES =
        hex"c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61";

    address internal token;
    address internal pool;
    address internal deployer;
    TokenAdminRegistry internal registry;
    RegistryModuleOwnerCustom internal registryModule;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
        registry = TokenAdminRegistry(networkConfig.tokenAdminRegistry);
        registryModule = RegistryModuleOwnerCustom(networkConfig.registryModuleOwnerCustom);
        // Chain-SCOPED, never the bare `TOKEN_POOL` alias: `vm.setEnv` is process-global and forge runs
        // suites in parallel, so a bare `TOKEN_POOL` here smears this Sepolia fixture across every other
        // suite's resolution ladder (it beat RegistryResolution's chain-scoped rung-2 assertion). This
        // fork is Sepolia, so the chain-scoped form resolves identically for any script this suite drives.
        vm.setEnv("ETHEREUM_SEPOLIA_TOKEN_POOL", vm.toString(pool));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Calldata parity: builder output == hand-written abi.encodeCall
    // ─────────────────────────────────────────────────────────────────────────

    function test_CctActions_ApplyChainUpdates_CalldataParity_EvmRemote() public view {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) =
            _evmChainUpdateInput(abi.encode(EVM_REMOTE_POOL), abi.encode(EVM_REMOTE_TOKEN), EVM_SELECTOR);

        CctActions.Call[] memory calls = CctActions.applyChainUpdates(pool, removes, updates);

        assertEq(calls.length, 1, "applyChainUpdates must be a single call");
        assertEq(calls[0].target, pool, "target must be the pool");
        assertEq(calls[0].value, 0, "value must be zero");
        assertEq(
            calls[0].data,
            abi.encodeCall(TokenPool.applyChainUpdates, (removes, updates)),
            "EVM-remote calldata mismatch vs hand-encoded expectation"
        );
    }

    function test_CctActions_ApplyChainUpdates_CalldataParity_SvmRemote() public view {
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) =
            _evmChainUpdateInput(SVM_REMOTE_POOL_BYTES, SVM_REMOTE_TOKEN_BYTES, SVM_SELECTOR);

        CctActions.Call[] memory calls = CctActions.applyChainUpdates(pool, removes, updates);

        assertEq(
            calls[0].data,
            abi.encodeCall(TokenPool.applyChainUpdates, (removes, updates)),
            "SVM-remote calldata mismatch vs hand-encoded expectation"
        );
        // The action layer must pass the pre-encoded 32 raw bytes through untouched.
        assertEq(updates[0].remotePoolAddresses[0], SVM_REMOTE_POOL_BYTES, "SVM pool bytes altered");
        assertEq(updates[0].remoteTokenAddress, SVM_REMOTE_TOKEN_BYTES, "SVM token bytes altered");
    }

    function test_CctActions_RegisterAccessControlDefaultAdmin_CalldataParity() public view {
        CctActions.Call[] memory calls = CctActions.registerAccessControlDefaultAdmin(address(registryModule), token);

        assertEq(calls.length, 1, "registerAccessControlDefaultAdmin must be a single call");
        assertEq(calls[0].target, address(registryModule), "target must be the registry module");
        assertEq(calls[0].value, 0, "value must be zero");
        assertEq(
            calls[0].data,
            abi.encodeCall(RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin, (token)),
            "AccessControl claim calldata mismatch vs hand-encoded expectation"
        );
    }

    function test_CctActions_SetPool_CalldataParity() public view {
        CctActions.Call[] memory calls = CctActions.setPool(address(registry), token, pool);

        assertEq(calls.length, 1, "setPool must be a single call");
        assertEq(calls[0].target, address(registry), "target must be the TokenAdminRegistry");
        assertEq(calls[0].value, 0, "value must be zero");
        assertEq(
            calls[0].data,
            abi.encodeCall(TokenAdminRegistry.setPool, (token, pool)),
            "setPool calldata mismatch vs hand-encoded expectation"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fork state parity: inline baseline vs script path
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev ClaimAdmin + AcceptAdminRole: the baseline calls
    ///      `registerAdminViaGetCCIPAdmin(token)` (the fixture token exposes `getCCIPAdmin()`, which the
    ///      script probe prefers) then `acceptAdminRole(token)` from the same signer. The scripts must
    ///      land the identical TokenConfig administrator.
    function test_ClaimAndAcceptAdmin_ForkStateParity() public {
        uint256 snapshot = vm.snapshotState();

        // Baseline path, replayed inline from the same signer.
        vm.prank(deployer);
        registryModule.registerAdminViaGetCCIPAdmin(token);
        vm.prank(deployer);
        registry.acceptAdminRole(token);
        address directAdministrator = registry.getTokenConfig(token).administrator;
        assertEq(directAdministrator, deployer, "direct calls must set the signer as administrator");

        vm.revertToState(snapshot);

        // The same result through the ClaimAdmin + AcceptAdminRole scripts.
        new ClaimAdmin().run();
        assertEq(
            registry.getTokenConfig(token).pendingAdministrator,
            directAdministrator,
            "ClaimAdmin pendingAdministrator mismatch"
        );
        new AcceptAdminRole().run();
        assertEq(
            registry.getTokenConfig(token).administrator,
            directAdministrator,
            "the scripts must land the same administrator as the direct calls"
        );
    }

    /// @dev The claim + accept registration pair executes correctly as ONE batch: the claim sets the
    ///      pending administrator to the calling account, so the accept in the same batch succeeds.
    function test_RegistrationPair_ExecutesAsOneBatch() public {
        CctActions.Call[] memory calls =
            CctActions.registerAndAcceptAdminViaGetCCIPAdmin(address(registryModule), address(registry), token);
        assertEq(calls.length, 2, "registration pair must be two calls");

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(deployer);
            (bool success,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            assertTrue(success, "registration-pair call failed");
        }
        assertEq(registry.getTokenConfig(token).administrator, deployer, "one-batch registration must complete");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(0), "pending must be cleared");
    }

    /// @dev A pure OZ AccessControl token, exposing only DEFAULT_ADMIN_ROLE and neither getCCIPAdmin() nor
    ///      owner(), registers through the real RegistryModuleOwnerCustom + TokenAdminRegistry via the
    ///      AccessControl claim path. Driven through _exec against the live fork's registry, with no
    ///      global TOKEN env mutation. The claim scripts' end-to-end AccessControl run() glue is proven on
    ///      a public testnet; here the action-layer pair is proven against the real on-chain registry.
    function test_RegisterViaAccessControl_ForkStateParity() public {
        AccessControlOnlyToken acToken = new AccessControlOnlyToken(deployer);

        CctActions.Call[] memory calls = CctActions.registerAndAcceptAdminViaAccessControl(
            address(registryModule), address(registry), address(acToken)
        );
        assertEq(calls.length, 2, "AccessControl registration pair must be two calls");
        _exec(deployer, calls);

        assertEq(
            registry.getTokenConfig(address(acToken)).administrator,
            deployer,
            "AccessControl-only token must register the DEFAULT_ADMIN_ROLE holder as administrator"
        );
        assertEq(
            registry.getTokenConfig(address(acToken)).pendingAdministrator,
            address(0),
            "pending must be cleared after the atomic pair"
        );
    }

    /// @dev SetPool: a direct `registry.setPool(token, pool)` and the SetPool script land the same
    ///      registry state.
    function test_SetPool_ForkStateParity() public {
        // Prerequisite for both paths: the signer is the token's registry administrator.
        vm.prank(deployer);
        registryModule.registerAdminViaGetCCIPAdmin(token);
        vm.prank(deployer);
        registry.acceptAdminRole(token);

        uint256 snapshot = vm.snapshotState();

        // Direct call.
        vm.prank(deployer);
        registry.setPool(token, pool);
        address directPool = registry.getPool(token);
        assertEq(directPool, pool, "the direct call must register the pool");

        vm.revertToState(snapshot);

        // Script path.
        assertEq(registry.getPool(token), address(0), "precondition: no pool registered");
        new SetPool().run();
        assertEq(registry.getPool(token), directPool, "SetPool must land the same registry state");
    }

    /// @notice All ownership scenarios run inside ONE test function on purpose: forge executes tests in
    ///         parallel and `vm.setEnv` is process-wide, so tests that set DIFFERENT values for the
    ///         transfer-ownership env vars (ENTITY_TYPE / ADDRESS / NEW_OWNER) would race. Sequential
    ///         phases with state snapshots keep the env deterministic while each script runs.
    function test_Ownership_ForkStateParity_AllScenarios() public {
        _poolOwnershipTwoStepParity();
        _acceptOwnershipPoolScript();
        _tokenDefaultAdminParity();
    }

    /// @dev Pool ownership two-step: a direct `transferOwnership` + `acceptOwnership` and the
    ///      TransferOwnership script (step 1) with the pending owner accepting (step 2) land the same owner.
    function _poolOwnershipTwoStepParity() internal {
        uint256 snapshot = vm.snapshotState();

        // Direct calls.
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(NEW_OWNER);
        vm.prank(NEW_OWNER);
        TokenPool(pool).acceptOwnership();
        address directOwner = TokenPool(pool).owner();
        assertEq(directOwner, NEW_OWNER, "the direct calls must complete the two-step transfer");

        vm.revertToState(snapshot);

        // Script path (step 1 via the script; step 2 executed by the pending owner).
        vm.setEnv("ENTITY_TYPE", "tokenPool");
        vm.setEnv("ADDRESS", vm.toString(pool));
        vm.setEnv("NEW_OWNER", vm.toString(NEW_OWNER));
        new TransferOwnership().run();

        vm.prank(NEW_OWNER);
        TokenPool(pool).acceptOwnership();
        assertEq(TokenPool(pool).owner(), directOwner, "the script must land the same owner");

        // Leave the fixture as setUp created it for the next phase.
        vm.revertToState(snapshot);
    }

    /// @dev AcceptOwnership script path: a pool whose pending owner is the script signer completes the
    ///      two-step through the script.
    function _acceptOwnershipPoolScript() internal {
        // A second pool owned by another account, with the script signer as pending owner.
        vm.prank(NEW_OWNER);
        BurnMintTokenPool otherPool =
            new BurnMintTokenPool(IBurnMintERC20(token), 18, address(0), networkConfig.rmnProxy, networkConfig.router);
        vm.prank(NEW_OWNER);
        otherPool.transferOwnership(deployer);

        vm.setEnv("ENTITY_TYPE", "tokenPool");
        vm.setEnv("ADDRESS", vm.toString(address(otherPool)));
        new AcceptOwnership().run();

        assertEq(otherPool.owner(), deployer, "the AcceptOwnership script must complete the transfer");
    }

    /// @dev Token default-admin two-step (CrossChainToken, AccessControlDefaultAdminRules): inline
    ///      baseline `beginDefaultAdminTransfer` + warp past the transfer schedule +
    ///      `acceptDefaultAdminTransfer` vs the TransferOwnership script and the action-layer accept
    ///      builder. The accept before the schedule reverts AccessControlEnforcedDefaultAdminDelay,
    ///      so both paths warp identically.
    function _tokenDefaultAdminParity() internal {
        IAccessControlDefaultAdminRules adminRules = IAccessControlDefaultAdminRules(token);
        uint256 snapshot = vm.snapshotState();

        // Direct calls: the two-step done inline.
        vm.prank(deployer);
        adminRules.beginDefaultAdminTransfer(NEW_OWNER);
        (, uint48 directSchedule) = adminRules.pendingDefaultAdmin();
        vm.warp(uint256(directSchedule) + 1);
        vm.prank(NEW_OWNER);
        adminRules.acceptDefaultAdminTransfer();
        address directAdmin = adminRules.defaultAdmin();
        assertEq(directAdmin, NEW_OWNER, "direct calls must complete the default-admin transfer");

        vm.revertToState(snapshot);

        // The TransferOwnership script plus the action-layer accept builder.
        vm.setEnv("ENTITY_TYPE", "token");
        vm.setEnv("ADDRESS", vm.toString(token));
        vm.setEnv("NEW_OWNER", vm.toString(NEW_OWNER));
        new TransferOwnership().run();

        (address pendingAdmin, uint48 schedule) = adminRules.pendingDefaultAdmin();
        assertEq(pendingAdmin, NEW_OWNER, "the TransferOwnership script must set the pending default admin");
        vm.warp(uint256(schedule) + 1);

        // Step 2 through the action-layer builder, executed by the pending admin.
        CctActions.Call[] memory calls = CctActions.acceptDefaultAdminTransfer(token);
        vm.prank(NEW_OWNER);
        (bool success,) = calls[0].target.call{value: calls[0].value}(calls[0].data);
        assertTrue(success, "acceptDefaultAdminTransfer call failed");

        assertEq(adminRules.defaultAdmin(), directAdmin, "the script path must land the same default admin");
    }

    /// @dev The fixture token's CCIP admin is the deployer, which is what makes the ClaimAdmin probe
    ///      pick the getCCIPAdmin claim path in these parity tests.
    function test_Fixture_ClaimProbe_PrefersGetCCIPAdmin() public view {
        assertEq(IGetCCIPAdmin(token).getCCIPAdmin(), deployer, "fixture CCIP admin must be the deployer");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _evmChainUpdateInput(bytes memory remotePool, bytes memory remoteToken, uint64 selector)
        internal
        pure
        returns (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates)
    {
        removes = new uint64[](0);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = remotePool;
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: selector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: remoteToken,
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
    }
}
