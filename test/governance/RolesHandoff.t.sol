// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {BaseERC20} from "@chainlink/contracts-ccip/contracts/tokens/BaseERC20.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {BurnMintERC677} from "@chainlink/contracts/src/v0.8/shared/token/ERC677/BurnMintERC677.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.3.0/access/IAccessControl.sol";

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {DeploySafe} from "../../script/governance/DeploySafe.s.sol";
import {DeployToken} from "../../script/deploy/DeployToken.s.sol";
import {GrantTokenRole} from "../../script/setup/token-roles/GrantTokenRole.s.sol";
import {RevokeTokenRole} from "../../script/setup/token-roles/RevokeTokenRole.s.sol";
import {TransferTokenAdmin} from "../../script/setup/token-roles/TransferTokenAdmin.s.sol";
import {SetCCIPAdmin} from "../../script/setup/token-roles/SetCCIPAdmin.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {RolesProbes} from "../../src/roles/RolesProbes.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
import {ISafe} from "../../src/base/ISafe.sol";
import {SafeBatchLoader} from "../../src/base/SafeBatchLoader.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Script harnesses: pin the token / role / holder / admin inputs via the virtual
// seams (the env vars are process-wide; `vm.setEnv` would race parallel suites).
// EOA mode broadcasts from the default script sender - the deployer EOA, exactly
// the ceremony's step-A executor.
// ─────────────────────────────────────────────────────────────────────────────

contract GrantTokenRoleHarness is GrantTokenRole {
    address private immutable i_token;
    string private s_role;
    address private immutable i_holder; // 0 = keep the script's default (executing account)

    constructor(address token_, string memory role_, address holder_) {
        i_token = token_;
        s_role = role_;
        i_holder = holder_;
    }

    function _resolveToken(HelperConfig.NetworkConfig memory, uint256) internal view override returns (address) {
        return i_token;
    }

    function _roleName() internal view override returns (string memory) {
        return s_role;
    }

    function _holder(address defaultHolder) internal view override returns (address) {
        return i_holder == address(0) ? defaultHolder : i_holder;
    }
}

/// @dev Safe-mode capture variant: preflights against the Safe (`_executingAccount()`), captures the
///      built calls instead of emitting/broadcasting.
contract GrantTokenRoleSafeCapture is GrantTokenRoleHarness {
    CctActions.Call[] public captured;

    constructor(address token_, string memory role_, address holder_) GrantTokenRoleHarness(token_, role_, holder_) {}

    function _executionMode() internal pure override returns (string memory) {
        return "safe";
    }

    function _executeCalls(CctActions.Call[] memory calls) internal override {
        for (uint256 i = 0; i < calls.length; i++) {
            captured.push(calls[i]);
        }
    }

    function capturedCount() external view returns (uint256) {
        return captured.length;
    }
}

contract RevokeTokenRoleHarness is RevokeTokenRole {
    address private immutable i_token;
    string private s_role;
    address private immutable i_holder; // 0 = the unset-env default the script must refuse

    constructor(address token_, string memory role_, address holder_) {
        i_token = token_;
        s_role = role_;
        i_holder = holder_;
    }

    function _resolveToken(HelperConfig.NetworkConfig memory, uint256) internal view override returns (address) {
        return i_token;
    }

    function _roleName() internal view override returns (string memory) {
        return s_role;
    }

    function _holder() internal view override returns (address) {
        return i_holder;
    }
}

contract TransferTokenAdminHarness is TransferTokenAdmin {
    address private immutable i_token;
    address private immutable i_newAdmin;
    bool private immutable i_accept;

    constructor(address token_, address newAdmin_, bool accept_) {
        i_token = token_;
        i_newAdmin = newAdmin_;
        i_accept = accept_;
    }

    function _resolveToken(HelperConfig.NetworkConfig memory, uint256) internal view override returns (address) {
        return i_token;
    }

    function _newAdmin() internal view override returns (address) {
        return i_newAdmin;
    }

    function _acceptLeg() internal view override returns (bool) {
        return i_accept;
    }
}

contract SetCCIPAdminHarness is SetCCIPAdmin {
    address private immutable i_token;
    address private immutable i_newAdmin; // 0 = keep the script's default (executing account)

    constructor(address token_, address newAdmin_) {
        i_token = token_;
        i_newAdmin = newAdmin_;
    }

    function _resolveToken(HelperConfig.NetworkConfig memory, uint256) internal view override returns (address) {
        return i_token;
    }

    function _newCcipAdmin(address defaultAdmin_) internal view override returns (address) {
        return i_newAdmin == address(0) ? defaultAdmin_ : i_newAdmin;
    }
}

/// @dev Safe-mode capture variant of SetCCIPAdmin (default-recipient regression guard).
contract SetCCIPAdminSafeCapture is SetCCIPAdminHarness {
    CctActions.Call[] public captured;

    constructor(address token_, address newAdmin_) SetCCIPAdminHarness(token_, newAdmin_) {}

    function _executionMode() internal pure override returns (string memory) {
        return "safe";
    }

    function _executeCalls(CctActions.Call[] memory calls) internal override {
        for (uint256 i = 0; i < calls.length; i++) {
            captured.push(calls[i]);
        }
    }

    function capturedCount() external view returns (uint256) {
        return captured.length;
    }
}

/// @dev A faithful factory-model (Ownable) token SURFACE: two-step ownership, owner-gated Ownable
///      mint/burn sets with enumerable getters, owner-gated setCCIPAdmin - the `FactoryBurnMintERC20`
///      shape without vendoring it. Detection keys on `owner()` answering while `DEFAULT_ADMIN_ROLE()`
///      does not.
contract FactoryModelToken {
    address public owner;
    address public pendingOwner;
    address private s_ccipAdmin;
    address[] private s_minters;
    address[] private s_burners;

    constructor() {
        owner = msg.sender;
        s_ccipAdmin = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only callable by owner");
        _;
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Must be proposed owner");
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function getCCIPAdmin() external view returns (address) {
        return s_ccipAdmin;
    }

    function setCCIPAdmin(address newAdmin) external onlyOwner {
        s_ccipAdmin = newAdmin;
    }

    function grantMintRole(address minter) external onlyOwner {
        if (!_in(s_minters, minter)) s_minters.push(minter);
    }

    function grantBurnRole(address burner) external onlyOwner {
        if (!_in(s_burners, burner)) s_burners.push(burner);
    }

    function revokeMintRole(address minter) external onlyOwner {
        _remove(s_minters, minter);
    }

    function revokeBurnRole(address burner) external onlyOwner {
        _remove(s_burners, burner);
    }

    function getMinters() external view returns (address[] memory) {
        return s_minters;
    }

    function getBurners() external view returns (address[] memory) {
        return s_burners;
    }

    function isMinter(address a) external view returns (bool) {
        return _in(s_minters, a);
    }

    function isBurner(address a) external view returns (bool) {
        return _in(s_burners, a);
    }

    function mint(address, uint256) external view {
        require(_in(s_minters, msg.sender), "Sender not minter");
    }

    function _in(address[] storage set, address a) private view returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == a) return true;
        }
        return false;
    }

    function _remove(address[] storage set, address a) private {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == a) {
                set[i] = set[set.length - 1];
                set.pop();
                return;
            }
        }
    }
}

/// @dev A contract with none of the admin surfaces - the BYO/unknown detection shape.
contract ByoShapeToken {
    uint256 public x;
}

/// @dev The v1.x LockRelease rebalancer surface (`getRebalancer`/`setRebalancer`) - the real 1.5.x
///      pool is not in the vendored 2.0.0 package, so a shim stands in, like `ILockReleaseV1Liquidity`.
contract MockV1LockReleasePool {
    address private s_rebalancer;

    function getRebalancer() external view returns (address) {
        return s_rebalancer;
    }

    function setRebalancer(address rebalancer) external {
        s_rebalancer = rebalancer;
    }
}

/// @dev typeAndVersion + owner(), but NEITHER of the first two storage slots holds the owner - the
///      unknown-layout shape the pending-owner storage probe must refuse rather than misread.
contract MockUnknownLayoutOwnable {
    uint256 private s_gap0 = 1;
    uint256 private s_gap1 = 2;
    address private s_owner;

    constructor() {
        s_owner = msg.sender;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "MockUnknownLayoutOwnable 1.0.0";
    }

    function owner() external view returns (address) {
        return s_owner;
    }
}

/// @dev Shared Safe fixture + declaration/audit plumbing for the handoff suites.
abstract contract RolesHandoffBase is BaseForkTest {
    uint256 internal constant OWNER1_KEY = 0xA11CE;
    uint256 internal constant OWNER2_KEY = 0xB0B;
    uint256 internal constant OWNER3_KEY = 0xC0FFEE;

    address internal deployer;
    ISafe internal safe;
    address internal safeAddr;
    RolesAuditor internal auditor;

    function _setUpSafe() internal {
        // Identical values to SafeModeForkTest/ExecuteBatchForkTest: the CREATE2 Safe address and every
        // env var below are constant, so parallel suites see one consistent environment.
        vm.setEnv(
            "SAFE_OWNERS",
            string.concat(
                vm.toString(vm.addr(OWNER1_KEY)),
                ",",
                vm.toString(vm.addr(OWNER2_KEY)),
                ",",
                vm.toString(vm.addr(OWNER3_KEY))
            )
        );
        vm.setEnv("SAFE_THRESHOLD", "2");
        vm.setEnv("SAFE_SALT_NONCE", "0");
        safe = ISafe(new DeploySafe().run());
        safeAddr = address(safe);
        vm.setEnv("SAFE_ADDRESS", vm.toString(safeAddr));
        vm.setEnv("SAFE_SIGNER_KEYS", string.concat(vm.toString(OWNER1_KEY), ",", vm.toString(OWNER2_KEY)));
        auditor = new RolesAuditor();
    }

    function _q(address a) internal pure returns (string memory) {
        return string.concat("\"", vm.toString(a), "\"");
    }

    /// @dev external shim so expectRevert applies to the whole Mode B execution.
    function execDirectExternal(ISafe execSafe, CctActions.Call[] memory calls) external {
        SafeMode._execDirect(execSafe, calls);
    }

    /// @dev The pre-C completion gate, exactly what `roles-check` exit 0 means: `RolesCheck.s.sol`
    ///      reverts ROLES_DRIFT iff `Result.fails != 0`, and `roles-check.sh` maps that to exit 1.
    function _gate(string memory declaration) internal returns (RolesAuditor.Result memory) {
        return auditor.auditJson("ethereum-testnet-sepolia", declaration);
    }
}

/// @title RolesHandoffForkTest - fixture (a): the default burnmint chain (CrossChainToken + v2
/// BurnMintTokenPool), full EOA→Safe ceremony in the documented A→gate→B→gate→C order.
/// @notice The four NEW primitives are driven through their run() entry points (harnesses pin inputs
/// via the virtual seams); the pre-existing primitives' legs (TAR transfer, pool ownership, dynamic
/// config) are driven through their `CctActions` builders - the exact calldata those scripts execute
/// (the ExecuteBatch.t.sol precedent; the scripts' env shells are exercised against live testnets).
/// Batches B and C execute through the `ExecuteBatch` composition (emit → loadMany → one
/// `execTransaction`) with the Safe as executor, never pranked-as-EOA.
contract RolesHandoffForkTest is RolesHandoffBase {
    address internal token;
    address internal pool;
    TokenAdminRegistry internal registry;
    address internal registryModule;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
        registry = TokenAdminRegistry(networkConfig.tokenAdminRegistry);
        registryModule = networkConfig.registryModuleOwnerCustom;
        _setUpSafe();
        // Pre-ceremony state: the deployer EOA is registered as the token's TAR administrator.
        _exec(deployer, CctActions._registerAndAcceptAdminViaGetCCIPAdmin(registryModule, address(registry), token));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ceremony steps
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Step A - EOA-executed, serial, grant/begin-only. Every call is safe to repeat.
    function _stepA() internal {
        _stepAWithoutBurnMintAdminGrant();
        new GrantTokenRoleHarness(token, "burnMintAdmin", safeAddr).run();
    }

    function _stepAWithoutBurnMintAdminGrant() internal {
        new TransferTokenAdminHarness(token, safeAddr, false).run(); // beginDefaultAdminTransfer(Safe)
        new SetCCIPAdminHarness(token, safeAddr).run(); // one-step: ccipAdmin -> Safe
        _exec(deployer, CctActions._transferAdminRole(address(registry), token, safeAddr));
        _exec(deployer, CctActions._transferOwnership(pool, safeAddr));
        // Router-preservation rule: read the live router, pass it back unchanged.
        (, address routerBefore,,) = RolesProbes._readPoolAdmins(pool);
        _exec(deployer, CctActions._setDynamicConfig(pool, routerBefore, safeAddr, safeAddr));
        (, address routerAfter,,) = RolesProbes._readPoolAdmins(pool);
        assertEq(routerAfter, routerBefore, "setDynamicConfig must preserve the router byte-identically");
    }

    function _stepBCalls() internal view returns (CctActions.Call[] memory) {
        return CctActions._concat(
            CctActions._concat(
                CctActions._acceptDefaultAdminTransfer(token), CctActions._acceptAdminRole(address(registry), token)
            ),
            CctActions._acceptOwnership(pool)
        );
    }

    /// @dev Step B - the Safe's accepts, composed via the ExecuteBatch mechanism (emit each primitive's
    ///      batch, loadMany, ONE atomic execTransaction). `tag` keeps the emitted batch filenames
    ///      unique per test: forge runs a suite's tests in PARALLEL, so a shared name would be
    ///      written and read concurrently (a mid-truncation read parses as empty JSON).
    function _stepB(string memory tag) internal {
        // AccessControlDefaultAdminRules requires the accept schedule to have STRICTLY passed; the
        // delay is 0 but a same-timestamp accept still reverts, so advance one second (a real chain
        // advances blocks between A and B anyway).
        vm.warp(block.timestamp + 1);
        string[] memory paths = new string[](3);
        paths[0] = SafeMode._emitBatch(
            string.concat("handoff-", tag, "-b-accept-admin"), safeAddr, CctActions._acceptDefaultAdminTransfer(token)
        );
        paths[1] = SafeMode._emitBatch(
            string.concat("handoff-", tag, "-b-accept-tar"),
            safeAddr,
            CctActions._acceptAdminRole(address(registry), token)
        );
        paths[2] = SafeMode._emitBatch(
            string.concat("handoff-", tag, "-b-accept-pool"), safeAddr, CctActions._acceptOwnership(pool)
        );
        CctActions.Call[] memory merged = SafeBatchLoader._loadMany(paths, block.chainid, safeAddr);
        SafeMode._execDirect(safe, merged);
    }

    function _stepCCalls() internal view returns (CctActions.Call[] memory) {
        return CctActions._concat(
            CctActions._concat(
                CctActions._revokeRole(token, _roleId("MINTER_ROLE()", RolesProbes.MINTER_ROLE), deployer),
                CctActions._revokeRole(token, _roleId("BURNER_ROLE()", RolesProbes.BURNER_ROLE), deployer)
            ),
            CctActions._revokeRole(token, _roleId("BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE), deployer)
        );
    }

    /// @dev Step C - the Safe's atomic revoke batch, LAST, only after the gate passed.
    function _stepC(string memory tag) internal {
        string[] memory paths = new string[](1);
        paths[0] = SafeMode._emitBatch(string.concat("handoff-", tag, "-c-revokes"), safeAddr, _stepCCalls());
        SafeMode._execDirect(safe, SafeBatchLoader._loadMany(paths, block.chainid, safeAddr));
    }

    function _fullCeremony(string memory tag) internal {
        _stepA();
        _stepB(tag);
        assertEq(_gate(_declaration(false)).fails, 0, "pre-C gate must pass before batch C");
        _stepC(tag);
    }

    function _roleId(string memory sig, bytes32 fallbackRole) internal view returns (bytes32) {
        return RolesProbes._roleIdOrDefault(token, sig, fallbackRole);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The committed declaration (fixture a has no enumerable sets, so the
    // intermediate and final declarations coincide - the three buckets:
    // single-holder slots = Safe with pendings 0x0; non-enumerable admin lists
    // = [Safe]; non-enumerable minters/burners = the final [pool].
    // ─────────────────────────────────────────────────────────────────────────

    function _declaration(bool withAddresses) internal view returns (string memory) {
        string memory rolesBlock = string.concat("\"roles\":{", _tokenDecl(), ",", _tarDecl(), ",", _poolDecl(), "}");
        if (!withAddresses) return string.concat("{", rolesBlock, "}");
        return string.concat(
            "{\"addresses\":{\"active\":{\"token\":", _q(token), ",\"tokenPool\":", _q(pool), "}},", rolesBlock, "}"
        );
    }

    function _tokenDecl() internal view returns (string memory) {
        string memory head = string.concat(
            "\"token\":{\"address\":",
            _q(token),
            ",\"type\":\"crosschain\",\"defaultAdmin\":",
            _q(safeAddr),
            ",\"ccipAdmin\":",
            _q(safeAddr)
        );
        string memory lists = string.concat(
            ",\"burnMintRoleAdmins\":{\"holders\":[",
            _q(safeAddr),
            "],\"complete\":false},\"minters\":{\"holders\":[",
            _q(pool),
            "],\"complete\":false},\"burners\":{\"holders\":[",
            _q(pool),
            "],\"complete\":false}}"
        );
        return string.concat(head, lists);
    }

    function _tarDecl() internal view returns (string memory) {
        return string.concat(
            "\"tokenAdminRegistry\":{\"registry\":",
            _q(address(registry)),
            ",\"administrator\":",
            _q(safeAddr),
            ",\"pendingAdministrator\":",
            _q(address(0)),
            "}"
        );
    }

    function _poolDecl() internal view returns (string memory) {
        return string.concat(
            "\"pool\":{\"address\":",
            _q(pool),
            ",\"owner\":",
            _q(safeAddr),
            ",\"rateLimitAdmin\":",
            _q(safeAddr),
            ",\"feeAdmin\":",
            _q(safeAddr),
            "}"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step-A grant-only invariant: the escape hatch
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Step A must be grant-only - the direct regression guard against an atomic handOffRole
    ///      leg leaking into TransferTokenAdmin: after ALL of step A, (a) the EOA still
    ///      holds every two-step pending / grant-model slot, and (b) for each one-step slot already
    ///      moved to the Safe, the EOA still holds the CONTROLLING PARENT that can reverse it.
    function test_handoff_stepA_grantOnly_eoaRetainsEscapeHatch() public {
        _stepA();

        // (a) the escape-hatch slots are still the EOA's.
        assertEq(CrossChainToken(token).defaultAdmin(), deployer, "defaultAdmin must NOT move in step A");
        (, address pendingDa) = RolesProbes._tryAddress(token, "pendingDefaultAdmin()");
        assertEq(pendingDa, safeAddr, "the default-admin transfer must be pending to the Safe");
        assertTrue(
            RolesProbes._hasRole(token, _roleId("BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE), deployer),
            "the EOA keeps BURN_MINT_ADMIN_ROLE until batch C"
        );
        assertTrue(
            RolesProbes._hasRole(token, _roleId("MINTER_ROLE()", RolesProbes.MINTER_ROLE), deployer),
            "the EOA keeps MINTER_ROLE until batch C"
        );
        assertTrue(
            RolesProbes._hasRole(token, _roleId("BURNER_ROLE()", RolesProbes.BURNER_ROLE), deployer),
            "the EOA keeps BURNER_ROLE until batch C"
        );
        assertEq(registry.getTokenConfig(token).administrator, deployer, "TAR administrator must NOT move in step A");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, safeAddr, "TAR transfer pending to the Safe");
        assertEq(TokenPool(pool).owner(), deployer, "pool owner must NOT move in step A");

        // The DENY sweep sees exactly this: the EOA still holds its escape-hatch slots (a FAIL set).
        RolesAuditor.Result memory r = auditor.auditJsonDeny("ethereum-testnet-sepolia", _declaration(true), deployer);
        assertGt(r.fails, 0, "DENY=<eoa> must FAIL during the escape-hatch window");
        assertTrue(vm.contains(r.failedFields, "MINTER_ROLE"), "the sweep names the retained MINTER_ROLE");

        // (b) one-step slots DID move in A, and the EOA holds each slot's controlling parent.
        assertEq(CrossChainToken(token).getCCIPAdmin(), safeAddr, "ccipAdmin is a one-step move in A");
        (,, address rla, address fee) = RolesProbes._readPoolAdmins(pool);
        assertEq(rla, safeAddr, "rateLimitAdmin is a one-step move in A");
        assertEq(fee, safeAddr, "feeAdmin is a one-step move in A");
        uint256 snapshot = vm.snapshotState();
        vm.prank(deployer); // DEFAULT_ADMIN_ROLE (still the EOA's) gates setCCIPAdmin - reversible.
        CrossChainToken(token).setCCIPAdmin(deployer);
        assertEq(CrossChainToken(token).getCCIPAdmin(), deployer, "the EOA can still reverse the ccipAdmin move");
        (, address router,,) = RolesProbes._readPoolAdmins(pool);
        vm.prank(deployer); // pool owner (still the EOA) gates setDynamicConfig - reversible.
        TokenPool(pool).setDynamicConfig(router, deployer, deployer);
        vm.revertToState(snapshot);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The two-phase completion gate
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The gate (not primitive-internal checks) enforces revoke-before-accept refusal: while any
    ///      pending is outstanding or an owner still reads the EOA, the gate exits 1 naming the field;
    ///      once B's accepts complete, the SAME gate on the SAME declaration returns clean - the
    ///      positive leg that authorizes C.
    function test_handoff_revokeBeforeAccept_refuses() public {
        _stepA();
        RolesAuditor.Result memory r = _gate(_declaration(false));
        assertGt(r.fails, 0, "the pre-C gate must refuse while the accepts are outstanding");
        assertTrue(vm.contains(r.failedFields, "token.pendingDefaultAdmin"), "names the outstanding token pending");
        assertTrue(vm.contains(r.failedFields, "tokenAdminRegistry.administrator"), "names the unmoved TAR admin");
        assertTrue(vm.contains(r.failedFields, "pool.owner"), "names the unmoved pool owner");

        _stepB("revoke-refuse");
        RolesAuditor.Result memory r2 = _gate(_declaration(false));
        assertEq(r2.fails, 0, "after B the gate must return clean, authorizing C");
    }

    /// @dev The non-enumerable admin-list declaration is load-bearing: withhold the step-A
    ///      BURN_MINT_ADMIN_ROLE grant and the gate
    ///      must FAIL naming that field - proving the declared [Safe] admin list VERIFIES the grant
    ///      landed rather than SKIPping it (batch C's revokes need that role, so a SKIP would let the
    ///      whole atomic C revert).
    function test_handoff_gate_preC_failsWhenSafeGrantMissing() public {
        _stepAWithoutBurnMintAdminGrant();
        _stepB("grant-missing");
        RolesAuditor.Result memory r = _gate(_declaration(false));
        assertGt(r.fails, 0, "the gate must refuse when the Safe's BURN_MINT_ADMIN_ROLE grant is missing");
        assertTrue(vm.contains(r.failedFields, "token.burnMintRoleAdmins"), "names the missing admin grant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Full ceremony: end state, negatives, DENY
    // ─────────────────────────────────────────────────────────────────────────

    function test_handoff_fullCeremony_endState() public {
        _fullCeremony("end-state");
        assertEq(CrossChainToken(token).defaultAdmin(), safeAddr, "defaultAdmin == Safe");
        assertEq(CrossChainToken(token).getCCIPAdmin(), safeAddr, "ccipAdmin == Safe");
        assertEq(registry.getTokenConfig(token).administrator, safeAddr, "TAR administrator == Safe");
        assertEq(registry.getTokenConfig(token).pendingAdministrator, address(0), "no TAR pending");
        assertEq(TokenPool(pool).owner(), safeAddr, "pool owner == Safe");
        (,, address rla, address fee) = RolesProbes._readPoolAdmins(pool);
        assertEq(rla, safeAddr, "rateLimitAdmin == Safe");
        assertEq(fee, safeAddr, "feeAdmin == Safe");
        // Post-C proof: the final declaration reconciles clean AND the DENY sweep is clean.
        assertEq(_gate(_declaration(false)).fails, 0, "post-C roles-check clean");
        RolesAuditor.Result memory deny =
            auditor.auditJsonDeny("ethereum-testnet-sepolia", _declaration(true), deployer);
        assertEq(deny.fails, 0, "post-C DENY=<deployerEOA> sweep clean");
    }

    /// @dev Post-handoff, an EOA call to EVERY privileged function reverts, and the governance path
    ///      succeeds for the same call, role by role.
    function test_handoff_crosschain_eoaNegatives() public {
        _fullCeremony("eoa-negatives");
        address stranger = makeAddr("post-handoff-recipient");
        bytes32 minterRole = _roleId("MINTER_ROLE()", RolesProbes.MINTER_ROLE);

        // EOA negatives.
        vm.prank(deployer);
        vm.expectRevert();
        IAccessControl(token).grantRole(minterRole, stranger); // BURN_MINT_ADMIN_ROLE moved
        vm.prank(deployer);
        vm.expectRevert();
        CrossChainToken(token).beginDefaultAdminTransfer(stranger); // defaultAdmin moved
        vm.prank(deployer);
        vm.expectRevert();
        CrossChainToken(token).setCCIPAdmin(stranger); // DEFAULT_ADMIN_ROLE moved
        vm.prank(deployer);
        vm.expectRevert();
        CrossChainToken(token).mint(stranger, 1e18); // MINTER_ROLE revoked
        vm.prank(deployer);
        vm.expectRevert();
        registry.transferAdminRole(token, stranger); // TAR administrator moved
        vm.prank(deployer);
        vm.expectRevert();
        registry.setPool(token, pool); // TAR administrator moved
        vm.prank(deployer);
        vm.expectRevert();
        TokenPool(pool).transferOwnership(stranger); // pool owner moved
        (, address router,,) = RolesProbes._readPoolAdmins(pool);
        vm.prank(deployer);
        vm.expectRevert();
        TokenPool(pool).setDynamicConfig(router, deployer, deployer); // pool owner moved
        vm.prank(deployer);
        vm.expectRevert();
        TokenPool(pool).setRateLimitConfig(new TokenPool.RateLimitConfigArgs[](0)); // owner/rateLimitAdmin moved

        // Governance path succeeds for each, role by role (snapshot-isolated).
        _assertGovernancePathWorks(stranger, minterRole, router);
    }

    function _assertGovernancePathWorks(address stranger, bytes32 minterRole, address router) internal {
        uint256 snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._grantRole(token, minterRole, stranger));
        assertTrue(RolesProbes._hasRole(token, minterRole, stranger), "Safe can grant mint");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._beginDefaultAdminTransfer(token, stranger));
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._setCCIPAdmin(token, stranger));
        assertEq(CrossChainToken(token).getCCIPAdmin(), stranger, "Safe can set ccipAdmin");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        // Day-2 mint under governance: grant-to-self + mint as ONE atomic Safe batch.
        SafeMode._execDirect(
            safe,
            CctActions._concat(
                CctActions._grantRole(token, minterRole, safeAddr), CctActions._mint(token, safeAddr, 1e18)
            )
        );
        assertEq(IERC20(token).balanceOf(safeAddr), 1e18, "Safe can mint via grant+mint batch");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._transferAdminRole(address(registry), token, stranger));
        assertEq(registry.getTokenConfig(token).pendingAdministrator, stranger, "Safe can move the TAR admin");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._transferOwnership(pool, stranger));
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._setDynamicConfig(pool, router, safeAddr, safeAddr));
        (, address routerAfter,,) = RolesProbes._readPoolAdmins(pool);
        assertEq(routerAfter, router, "the governance setDynamicConfig preserves the router");
        vm.revertToState(snapshot);
    }

    /// @dev CrossChainToken's forbidden mechanism: grantRole(DEFAULT_ADMIN_ROLE, ...) always reverts
    ///      (AccessControlDefaultAdminRules forbids it - the two-step transfer is the ONLY path).
    function test_handoff_crosschain_grantDefaultAdmin_reverts() public {
        vm.prank(deployer);
        vm.expectRevert();
        IAccessControl(token).grantRole(RolesProbes.DEFAULT_ADMIN_ROLE, safeAddr);
    }

    /// @dev The pool's pending owner has no getter (Chainlink Ownable2Step keeps it private); the
    ///      storage probe reads it, self-checked against the live owner(). Through the ceremony it
    ///      must read: none before A, the Safe after A (the step-A action is VISIBLE, not inferred),
    ///      none again after B's accept. The auditor surfaces the in-flight window as a WARN.
    function test_handoff_pendingOwnerProbe_tracksCeremony() public {
        (bool ok0, address pending0) = RolesProbes._tryPendingOwner(pool);
        assertTrue(ok0, "the probe must read a known pool layout");
        assertEq(pending0, address(0), "no transfer pending before step A");

        _stepA();
        (bool okA, address pendingA) = RolesProbes._tryPendingOwner(pool);
        assertTrue(okA, "probe readable after A");
        assertEq(pendingA, safeAddr, "step A's transferOwnership is pending to the Safe");
        // The auditor shows the in-flight window: audit a declaration matching the LIVE mid-ceremony
        // state (owner still the EOA) and expect the pendingOwner WARN, not a silent pass.
        RolesAuditor.Result memory r = _gate(_midCeremonyDeclaration());
        assertEq(r.fails, 0, "the live-true declaration reconciles");
        assertGt(r.warns, 0, "the in-flight pending owner is a WARN");

        _stepB("pending-probe");
        (bool okB, address pendingB) = RolesProbes._tryPendingOwner(pool);
        assertTrue(okB, "probe readable after B");
        assertEq(pendingB, address(0), "the accept cleared the pending owner");
    }

    /// @dev A declaration equal to the LIVE state right after step A (owner slots still the EOA's).
    function _midCeremonyDeclaration() internal view returns (string memory) {
        return string.concat(
            "{\"roles\":{\"token\":{\"address\":",
            _q(token),
            ",\"type\":\"crosschain\",\"defaultAdmin\":",
            _q(deployer),
            ",\"pendingDefaultAdmin\":",
            _q(safeAddr),
            "},\"pool\":{\"address\":",
            _q(pool),
            ",\"owner\":",
            _q(deployer),
            ",\"rateLimitAdmin\":",
            _q(safeAddr),
            ",\"feeAdmin\":",
            _q(safeAddr),
            "}}}"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Resume / idempotence / atomicity
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Crash after A: the committed declaration's field diff IS the resume point - resume with B
    ///      and C from live state, ending in the identical end state as an uninterrupted run.
    function test_handoff_partialResume() public {
        _stepA();
        // The crash-recovery read: the gate names exactly the not-yet-executed accepts.
        RolesAuditor.Result memory r = _gate(_declaration(false));
        assertGt(r.fails, 0, "mid-ceremony the declaration names the remaining steps");
        // Resume from the diff (the accepts), never by re-running completed A steps.
        _stepB("partial-resume");
        assertEq(_gate(_declaration(false)).fails, 0, "resumed ceremony passes the pre-C gate");
        _stepC("partial-resume");
        assertEq(CrossChainToken(token).defaultAdmin(), safeAddr, "resumed end state identical");
        assertEq(TokenPool(pool).owner(), safeAddr, "resumed end state identical");
        RolesAuditor.Result memory deny =
            auditor.auditJsonDeny("ethereum-testnet-sepolia", _declaration(true), deployer);
        assertEq(deny.fails, 0, "resumed ceremony ends DENY-clean");
    }

    /// @dev Every A step is idempotent: re-running the whole of step A leaves the state byte-identical.
    function test_handoff_rerunCompletedStep_idempotent() public {
        _stepA();
        bytes32 before = _stateDigest();
        _stepA();
        assertEq(_stateDigest(), before, "re-running step A must not change any slot");
    }

    function _stateDigest() internal view returns (bytes32) {
        (, address pendingDa) = RolesProbes._tryAddress(token, "pendingDefaultAdmin()");
        (,, address rla, address fee) = RolesProbes._readPoolAdmins(pool);
        return keccak256(
            abi.encode(
                CrossChainToken(token).defaultAdmin(),
                pendingDa,
                CrossChainToken(token).getCCIPAdmin(),
                registry.getTokenConfig(token).administrator,
                registry.getTokenConfig(token).pendingAdministrator,
                TokenPool(pool).owner(),
                rla,
                fee
            )
        );
    }

    /// @dev B is atomic: a completed accept batch re-run reverts AS A WHOLE (accepts revert when
    ///      nothing is pending) with no state change and no consumed nonce.
    function test_handoff_rerunCompletedAcceptBatch_revertsWholeNoStateChange() public {
        _stepA();
        _stepB("rerun-accept");
        bytes32 before = _stateDigest();
        vm.expectRevert(bytes("GS013"));
        this.execDirectExternal(safe, _stepBCalls());
        assertEq(_stateDigest(), before, "a re-run accept batch must leave zero state change");
    }

    /// @dev Batch B through the ExecuteBatch composition consumes exactly ONE Safe nonce - the atomic
    ///      execution is itself the proof the Safe can execute before anything is revoked.
    function test_handoff_acceptBatchB_oneNonce_viaExecuteBatchComposition() public {
        _stepA();
        uint256 nonceBefore = safe.nonce();
        _stepB("one-nonce");
        assertEq(safe.nonce(), nonceBefore + 1, "the three accepts must consume exactly ONE Safe nonce");
    }

    /// @dev Revoking a role its target never held is a no-op that cannot revert the ceremony or
    ///      disturb the end state.
    function test_handoff_neverGrantedRole() public {
        _fullCeremony("never-granted");
        address neverHolder = makeAddr("never-granted");
        SafeMode._execDirect(
            safe, CctActions._revokeRole(token, _roleId("MINTER_ROLE()", RolesProbes.MINTER_ROLE), neverHolder)
        );
        assertEq(_gate(_declaration(false)).fails, 0, "revoking an unheld role never breaks the end state");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The DENY sweep
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Seed ONE residual EOA slot (a MINTER_ROLE re-grant - a non-enumerable role a plain
    ///      roles-check cannot rule out) and the sweep must FAIL naming exactly that slot.
    function test_denyCheck_reportsResidualHolder() public {
        _fullCeremony("deny-residual");
        SafeMode._execDirect(
            safe, CctActions._grantRole(token, _roleId("MINTER_ROLE()", RolesProbes.MINTER_ROLE), deployer)
        );
        RolesAuditor.Result memory r = auditor.auditJsonDeny("ethereum-testnet-sepolia", _declaration(true), deployer);
        assertGt(r.fails, 0, "a residual MINTER_ROLE must FAIL the sweep");
        assertTrue(vm.contains(r.failedFields, "MINTER_ROLE"), "the sweep names the residual slot");
        assertTrue(vm.contains(r.failedFields, vm.toString(token)), "the sweep names the holding contract");
        assertFalse(vm.contains(r.failedFields, "BURNER_ROLE"), "no other slot is named");
    }

    function test_denyCheck_cleanState_passes() public {
        _fullCeremony("deny-clean");
        RolesAuditor.Result memory r = auditor.auditJsonDeny("ethereum-testnet-sepolia", _declaration(true), deployer);
        assertEq(r.fails, 0, "the post-ceremony fixture must sweep clean");
    }

    /// @dev Post-handoff regression: a FRESH deploy grants MINTER/BURNER to the deployer again (the
    ///      ROLES_RECIPIENT default), and the DENY sweep catches it because it enumerates from
    ///      addresses{} - a freshly deployed, not-yet-snapshotted token is in scope. With the roles
    ///      granted to the Safe instead, the sweep stays clean. (The second token is deployed directly
    ///      with the Safe as recipient rather than via DeployToken with ROLES_RECIPIENT env - that env
    ///      is process-wide and would poison parallel suites' fixtures; live-testnet runs drive the
    ///      documented `ROLES_RECIPIENT=$SAFE` command for real.)
    function test_postHandoff_freshDeploy_defaultRecipient_failsDenyCheck() public {
        _fullCeremony("fresh-deploy");

        // Default-recipient deploy: the repo's own DeployToken (grants land on the deployer EOA).
        uint256 nonceBefore = vm.getNonce(deployer);
        new DeployToken().run();
        address freshDefault = vm.computeCreateAddress(deployer, nonceBefore);
        RolesAuditor.Result memory r =
            auditor.auditJsonDeny("ethereum-testnet-sepolia", _declarationWithExtraDeployment(freshDefault), deployer);
        assertGt(r.fails, 0, "a fresh default-recipient deploy must fail the DENY sweep");
        assertTrue(vm.contains(r.failedFields, vm.toString(freshDefault)), "the sweep names the fresh token");
        assertTrue(vm.contains(r.failedFields, "MINTER_ROLE"), "the sweep names the regressed mint grant");

        // Safe-recipient deploy: same token shape, roles granted to the Safe -> the sweep stays clean.
        vm.startPrank(deployer);
        CrossChainToken freshSafe = new CrossChainToken(
            BaseERC20.ConstructorParams({
                name: "Handoff Safe Recipient",
                symbol: "HSR",
                maxSupply: 0,
                preMint: 0,
                preMintRecipient: address(0),
                decimals: 18,
                ccipAdmin: address(0)
            }),
            deployer,
            deployer
        );
        freshSafe.grantMintAndBurnRoles(safeAddr);
        freshSafe.beginDefaultAdminTransfer(safeAddr);
        freshSafe.grantRole(freshSafe.BURN_MINT_ADMIN_ROLE(), safeAddr);
        freshSafe.setCCIPAdmin(safeAddr);
        vm.stopPrank();
        vm.warp(block.timestamp + 1); // the accept schedule must have strictly passed
        SafeMode._execDirect(safe, CctActions._acceptDefaultAdminTransfer(address(freshSafe)));
        SafeMode._execDirect(
            safe,
            CctActions._concat(
                CctActions._concat(
                    CctActions._revokeRole(address(freshSafe), freshSafe.MINTER_ROLE(), deployer),
                    CctActions._revokeRole(address(freshSafe), freshSafe.BURNER_ROLE(), deployer)
                ),
                CctActions._revokeRole(address(freshSafe), freshSafe.BURN_MINT_ADMIN_ROLE(), deployer)
            )
        );
        RolesAuditor.Result memory r2 = auditor.auditJsonDeny(
            "ethereum-testnet-sepolia", _declarationWithExtraDeployment(address(freshSafe)), deployer
        );
        assertEq(r2.fails, 0, "a Safe-recipient deploy keeps the sweep clean");
    }

    function _declarationWithExtraDeployment(address extra) internal view returns (string memory) {
        // The fixture declaration plus a deployments{} entry for the extra token - the sweep reads
        // active AND deployments, so the not-yet-snapshotted token is in scope.
        return string.concat(
            "{\"addresses\":{\"active\":{\"token\":",
            _q(token),
            ",\"tokenPool\":",
            _q(pool),
            "},\"deployments\":{\"Fresh_Token\":",
            _q(extra),
            "}},",
            // reuse the roles block of _declaration
            _rolesBlockOnly(),
            "}"
        );
    }

    function _rolesBlockOnly() internal view returns (string memory) {
        string memory withBraces = _declaration(false); // "{"roles":{...}}"
        bytes memory b = bytes(withBraces);
        // strip the outer braces to splice the roles block into a larger document
        bytes memory inner = new bytes(b.length - 2);
        for (uint256 i = 1; i < b.length - 1; i++) {
            inner[i - 1] = b[i];
        }
        return string(inner);
    }
}

/// @title RolesHandoffLockboxHooksForkTest - fixture (b): a v2 LockRelease chain with an ERC20LockBox
/// and AdvancedPoolHooks attached, driving the lockbox/hooks owner + authorizedCallers rows (the
/// enumerable surfaces fixture (a) does not have). The contracts are constructed directly (pranked as
/// the deployer EOA) - the deploy-script env names (`ETHEREUM_SEPOLIA_LOCK_BOX`, `ALLOWLIST`) are
/// process-wide and suite-specific values would poison the parallel Lockbox/Hooks suites.
contract RolesHandoffLockboxHooksForkTest is RolesHandoffBase {
    address internal token;
    LockReleaseTokenPool internal pool;
    ERC20LockBox internal lockbox;
    AdvancedPoolHooks internal hooks;

    function setUp() public override {
        super.setUp();
        token = deployTokenFixture();
        deployer = _scriptBroadcaster();
        _setUpSafe();

        vm.startPrank(deployer);
        lockbox = new ERC20LockBox(token);
        hooks = new AdvancedPoolHooks(new address[](0), 0, address(0), new address[](0));
        pool = new LockReleaseTokenPool(
            IERC20(token), 18, address(hooks), networkConfig.rmnProxy, networkConfig.router, address(lockbox)
        );
        // Live pre-C membership: the pool AND the deployer EOA are authorized callers on both sets.
        address[] memory adds = new address[](2);
        adds[0] = address(pool);
        adds[1] = deployer;
        lockbox.applyAuthorizedCallerUpdates(
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: new address[](0)})
        );
        hooks.applyAuthorizedCallerUpdates(
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: new address[](0)})
        );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ceremony (the lockbox/hooks extension rows)
    // ─────────────────────────────────────────────────────────────────────────

    function _stepA() internal {
        _exec(deployer, CctActions._transferOwnership(address(pool), safeAddr));
        _exec(deployer, CctActions._transferOwnership(address(lockbox), safeAddr));
        _exec(deployer, CctActions._transferOwnership(address(hooks), safeAddr));
        (, address router,,) = RolesProbes._readPoolAdmins(address(pool));
        _exec(deployer, CctActions._setDynamicConfig(address(pool), router, safeAddr, safeAddr));
    }

    /// @dev `tag` keeps batch filenames unique per test - forge runs a suite's tests in parallel.
    function _stepB(string memory tag) internal {
        string[] memory paths = new string[](3);
        paths[0] = SafeMode._emitBatch(
            string.concat("lbhandoff-", tag, "-b-accept-pool"), safeAddr, CctActions._acceptOwnership(address(pool))
        );
        paths[1] = SafeMode._emitBatch(
            string.concat("lbhandoff-", tag, "-b-accept-lockbox"),
            safeAddr,
            CctActions._acceptOwnership(address(lockbox))
        );
        paths[2] = SafeMode._emitBatch(
            string.concat("lbhandoff-", tag, "-b-accept-hooks"), safeAddr, CctActions._acceptOwnership(address(hooks))
        );
        SafeMode._execDirect(safe, SafeBatchLoader._loadMany(paths, block.chainid, safeAddr));
    }

    function _stepC(string memory tag) internal {
        address[] memory removes = new address[](1);
        removes[0] = deployer;
        CctActions.Call[] memory calls = CctActions._concat(
            CctActions._applyAuthorizedCallerUpdates(address(lockbox), new address[](0), removes),
            CctActions._applyAuthorizedCallerUpdates(address(hooks), new address[](0), removes)
        );
        string[] memory paths = new string[](1);
        paths[0] = SafeMode._emitBatch(string.concat("lbhandoff-", tag, "-c-callers"), safeAddr, calls);
        SafeMode._execDirect(safe, SafeBatchLoader._loadMany(paths, block.chainid, safeAddr));
    }

    /// @dev The token's own handoff (this fixture's ceremony covers the lockbox/hooks rows; the deny
    ///      sweep covers EVERY anchored contract, so the sweep-asserting tests move the token too).
    function _handOffTokenSlots() internal {
        bytes32 bmaRole =
            RolesProbes._roleIdOrDefault(token, "BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE);
        vm.startPrank(deployer);
        CrossChainToken(token).grantRole(bmaRole, safeAddr);
        CrossChainToken(token).setCCIPAdmin(safeAddr);
        CrossChainToken(token).beginDefaultAdminTransfer(safeAddr);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        SafeMode._execDirect(safe, CctActions._acceptDefaultAdminTransfer(token));
        SafeMode._execDirect(
            safe,
            CctActions._concat(
                CctActions._concat(
                    CctActions._revokeRole(
                        token, RolesProbes._roleIdOrDefault(token, "MINTER_ROLE()", RolesProbes.MINTER_ROLE), deployer
                    ),
                    CctActions._revokeRole(
                        token, RolesProbes._roleIdOrDefault(token, "BURNER_ROLE()", RolesProbes.BURNER_ROLE), deployer
                    )
                ),
                CctActions._revokeRole(token, bmaRole, deployer)
            )
        );
    }

    /// @dev The INTERMEDIATE declaration: owners = Safe; enumerable authorizedCallers = the live
    ///      pre-C set INCLUDING the deployer EOA (the EOA's removal IS batch C).
    function _intermediateDeclaration() internal view returns (string memory) {
        return _declaration(true);
    }

    /// @dev The FINAL declaration: the enumerable sets now exclude the EOA.
    function _finalDeclaration() internal view returns (string memory) {
        return _declaration(false);
    }

    function _declaration(bool eoaInSets) internal view returns (string memory) {
        string memory callers = eoaInSets
            ? string.concat("[", _q(address(pool)), ",", _q(deployer), "]")
            : string.concat("[", _q(address(pool)), "]");
        return
            string.concat(
                "{\"roles\":{", _tokenAndPoolDecl(), ",", _lockboxDecl(callers), ",", _hooksDecl(callers), "}}"
            );
    }

    function _tokenAndPoolDecl() internal view returns (string memory) {
        string memory tokenBlock = string.concat(
            "\"token\":{\"address\":", _q(token), ",\"type\":\"crosschain\",\"defaultAdmin\":", _q(deployer), "}"
        );
        string memory poolBlock = string.concat(
            "\"pool\":{\"address\":",
            _q(address(pool)),
            ",\"owner\":",
            _q(safeAddr),
            ",\"rateLimitAdmin\":",
            _q(safeAddr),
            ",\"feeAdmin\":",
            _q(safeAddr),
            ",\"hooks\":",
            _q(address(hooks)),
            "}"
        );
        return string.concat(tokenBlock, ",", poolBlock);
    }

    function _lockboxDecl(string memory callers) internal view returns (string memory) {
        return string.concat(
            "\"lockbox\":{\"address\":",
            _q(address(lockbox)),
            ",\"owner\":",
            _q(safeAddr),
            ",\"authorizedCallers\":",
            callers,
            "}"
        );
    }

    function _hooksDecl(string memory callers) internal view returns (string memory) {
        return string.concat(
            "\"hooks\":{\"address\":",
            _q(address(hooks)),
            ",\"owner\":",
            _q(safeAddr),
            ",\"allowlistEnabled\":false,\"allowlist\":[],\"policyEngine\":",
            _q(address(0)),
            ",\"authorizedCallers\":",
            callers,
            "}"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Intermediate-declaration satisfiability + the post-C crash window
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The pre-C gate passes with the EOA still a LIVE member of the enumerable sets - proving the
    ///      intermediate declaration is satisfiable (a declaration already excluding the EOA would
    ///      deadlock the ceremony against its own runbook).
    function test_handoff_gate_passesPreC_withEoaInEnumerableSet() public {
        _stepA();
        // The pending-owner storage probe makes step A's three transfers VISIBLE (no getter exists):
        // pool, lockbox and hooks all pending to the Safe before the accepts run.
        (bool okPool, address pendingPool) = RolesProbes._tryPendingOwner(address(pool));
        (bool okLb, address pendingLb) = RolesProbes._tryPendingOwner(address(lockbox));
        (bool okHooks, address pendingHooks) = RolesProbes._tryPendingOwner(address(hooks));
        assertTrue(okPool && okLb && okHooks, "all three known layouts are readable");
        assertEq(pendingPool, safeAddr, "pool ownership pending to the Safe after A");
        assertEq(pendingLb, safeAddr, "lockbox ownership pending to the Safe after A");
        assertEq(pendingHooks, safeAddr, "hooks ownership pending to the Safe after A");

        _stepB("eoa-in-set");
        assertTrue(RolesProbes._contains(lockbox.getAllAuthorizedCallers(), deployer), "the EOA is still a live member");
        RolesAuditor.Result memory r = _gate(_intermediateDeclaration());
        assertEq(r.fails, 0, "the pre-C gate must pass with the EOA in the enumerable sets");
        (, address clearedLb) = RolesProbes._tryPendingOwner(address(lockbox));
        assertEq(clearedLb, address(0), "the lockbox accept cleared its pending owner");
    }

    /// @dev The after-C-before-final-commit crash window: the STALE intermediate declaration fails with
    ///      EXACTLY the enumerable EOA-membership rows and nothing else - the machine-readable "now
    ///      commit the final declaration" fingerprint (the declaration is behind the chain; the fix is
    ///      the commit, never on-chain remediation toward the intermediate state).
    function test_handoff_postC_staleIntermediateDeclaration_failsOnlyOnEnumerableEoaRows() public {
        _stepA();
        _stepB("stale-decl");
        assertEq(_gate(_intermediateDeclaration()).fails, 0, "pre-C gate authorizes C");
        _stepC("stale-decl");
        RolesAuditor.Result memory r = _gate(_intermediateDeclaration());
        assertEq(r.fails, 2, "exactly the two enumerable rows fail");
        assertTrue(vm.contains(r.failedFields, "lockbox.authorizedCallers"), "names the lockbox set");
        assertTrue(vm.contains(r.failedFields, "hooks.authorizedCallers"), "names the hooks set");
        // The final declaration is the fix.
        assertEq(_gate(_finalDeclaration()).fails, 0, "the committed final declaration reconciles clean");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lockbox/hooks negatives + the enumerable DENY case
    // ─────────────────────────────────────────────────────────────────────────

    function test_handoff_lockboxHooks_eoaNegatives() public {
        _stepA();
        _stepB("lb-negatives");
        _stepC("lb-negatives");
        _handOffTokenSlots();

        address[] memory adds = new address[](1);
        adds[0] = deployer;
        AuthorizedCallers.AuthorizedCallerArgs memory readd =
            AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: new address[](0)});

        // EOA negatives: owner-gated and membership-gated calls all revert.
        vm.prank(deployer);
        vm.expectRevert();
        lockbox.applyAuthorizedCallerUpdates(readd); // lockbox owner moved
        vm.prank(deployer);
        vm.expectRevert();
        lockbox.withdraw(token, 0, 1, deployer); // EOA no longer an authorized caller
        vm.prank(deployer);
        vm.expectRevert();
        hooks.applyAuthorizedCallerUpdates(readd); // hooks owner moved
        vm.prank(deployer);
        vm.expectRevert();
        hooks.setThresholdAmount(1e18); // hooks owner moved
        vm.prank(deployer);
        vm.expectRevert();
        hooks.applyCCVConfigUpdates(new AdvancedPoolHooks.CCVConfigArg[](0)); // hooks owner moved
        vm.prank(deployer);
        vm.expectRevert();
        lockbox.transferOwnership(deployer); // lockbox owner moved
        vm.prank(deployer);
        vm.expectRevert();
        hooks.transferOwnership(deployer); // hooks owner moved

        // Governance path works for the same surfaces.
        uint256 snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._setThresholdAmount(address(hooks), 1e18));
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._applyAuthorizedCallerUpdates(address(hooks), adds, new address[](0)));
        assertTrue(RolesProbes._contains(hooks.getAllAuthorizedCallers(), deployer), "Safe can edit the callers set");
        vm.revertToState(snapshot);

        // End state: DENY sweep on the lockbox/hooks/pool surface is clean.
        RolesAuditor.Result memory deny = auditor.auditJsonDeny("ethereum-testnet-sepolia", _denyDoc(), deployer);
        assertEq(deny.fails, 0, "post-C the lockbox/hooks surface sweeps clean");
    }

    /// @dev A claimable pending is as much a held slot as a current one: leave (or re-insert) the
    ///      retired EOA as the lockbox's pending owner post-ceremony and the sweep must FAIL - the
    ///      EOA could acceptOwnership() at will, and Chainlink Ownable2Step exposes no getter, so
    ///      only the storage probe can see it.
    function test_denyCheck_reportsResidualPendingOwner() public {
        _stepA();
        _stepB("deny-pending");
        _stepC("deny-pending");
        _handOffTokenSlots();
        RolesAuditor.Result memory clean = auditor.auditJsonDeny("ethereum-testnet-sepolia", _denyDoc(), deployer);
        assertEq(clean.fails, 0, "post-ceremony baseline sweeps clean");

        // The Safe (current owner) starts a transfer back to the retired EOA - pending, not accepted.
        SafeMode._execDirect(safe, CctActions._transferOwnership(address(lockbox), deployer));
        (bool ok, address pending) = RolesProbes._tryPendingOwner(address(lockbox));
        assertTrue(ok && pending == deployer, "precondition: the EOA is the claimable pending owner");

        RolesAuditor.Result memory r = auditor.auditJsonDeny("ethereum-testnet-sepolia", _denyDoc(), deployer);
        assertGt(r.fails, 0, "a claimable pending ownership must FAIL the sweep");
        assertTrue(vm.contains(r.failedFields, "pendingOwner"), "the sweep names the pending slot");
        assertTrue(vm.contains(r.failedFields, vm.toString(address(lockbox))), "the sweep names the lockbox");
    }

    /// @dev The enumerable-set residual case: seed the deployer BACK into the lockbox callers post-C
    ///      and the sweep must FAIL naming exactly that set.
    function test_denyCheck_reportsResidualHolder_enumerableSet() public {
        _stepA();
        _stepB("deny-set");
        _stepC("deny-set");
        _handOffTokenSlots();
        address[] memory adds = new address[](1);
        adds[0] = deployer;
        SafeMode._execDirect(safe, CctActions._applyAuthorizedCallerUpdates(address(lockbox), adds, new address[](0)));

        RolesAuditor.Result memory r = auditor.auditJsonDeny("ethereum-testnet-sepolia", _denyDoc(), deployer);
        assertGt(r.fails, 0, "a residual enumerable membership must FAIL the sweep");
        assertTrue(vm.contains(r.failedFields, "authorizedCallers"), "the sweep names the enumerable set");
        assertTrue(vm.contains(r.failedFields, vm.toString(address(lockbox))), "the sweep names the lockbox");
    }

    /// @dev The deny document for the COMPLETE chain: the sweep unions addresses{} with the declared
    ///      roles{} anchors, so the token is in scope too - the sweep-asserting tests run
    ///      _handOffTokenSlots() first (a chain sweeps clean only when EVERY contract did).
    function _denyDoc() internal view returns (string memory) {
        return string.concat(
            "{\"addresses\":{\"active\":{\"tokenPool\":",
            _q(address(pool)),
            ",\"lockBox\":",
            _q(address(lockbox)),
            ",\"poolHooks\":",
            _q(address(hooks)),
            "}},",
            // minimal roles anchors so the audit half runs against live-true values
            "\"roles\":{\"token\":{\"address\":",
            _q(token),
            ",\"type\":\"crosschain\",\"defaultAdmin\":",
            _q(safeAddr),
            "},\"pool\":{\"address\":",
            _q(address(pool)),
            ",\"owner\":",
            _q(safeAddr),
            "}}}"
        );
    }
}

/// @title TokenRoleTemplatesForkTest - the per-template mini-ceremonies (burnmint grant/revoke model,
/// factory Ownable model), the BYO refusal shape, the role×template mismatch guards, and the
/// default-actor (executingAccount) regression guards.
contract TokenRoleTemplatesForkTest is RolesHandoffBase {
    address internal fixturePool;

    BurnMintERC20 internal bm;
    FactoryModelToken internal factory;
    ByoShapeToken internal byo;

    function setUp() public override {
        super.setUp();
        (, fixturePool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();
        _setUpSafe();
        vm.startPrank(deployer);
        bm = new BurnMintERC20("Handoff BM", "HBM", 18, 0, 0);
        bm.grantMintAndBurnRoles(deployer);
        factory = new FactoryModelToken();
        factory.grantMintRole(deployer);
        factory.grantBurnRole(deployer);
        vm.stopPrank();
        byo = new ByoShapeToken();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // burnmint: the grant/revoke model
    // ─────────────────────────────────────────────────────────────────────────

    function test_handoff_burnmint_eoaNegatives() public {
        // Step A (grant-only): DEFAULT_ADMIN grant + ccipAdmin one-step move.
        new TransferTokenAdminHarness(address(bm), safeAddr, false).run();
        new SetCCIPAdminHarness(address(bm), safeAddr).run();
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, deployer), "grant-only: the EOA keeps DEFAULT_ADMIN");
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, safeAddr), "the Safe now holds DEFAULT_ADMIN");

        // No step B on the grant model: the accept leg refuses by name.
        TransferTokenAdminHarness acceptLeg = new TransferTokenAdminHarness(address(bm), safeAddr, true);
        vm.expectRevert(
            bytes("burnmint token: the grant model has no accept leg - the step-A grantRole is already effective")
        );
        acceptLeg.run();

        // Step C (the Safe revokes every residual EOA power) - the Safe, as the new admin, executes it.
        SafeMode._execDirect(
            safe,
            CctActions._concat(
                CctActions._concat(
                    CctActions._revokeRole(address(bm), bm.MINTER_ROLE(), deployer),
                    CctActions._revokeRole(address(bm), bm.BURNER_ROLE(), deployer)
                ),
                CctActions._revokeRole(address(bm), RolesProbes.DEFAULT_ADMIN_ROLE, deployer)
            )
        );

        // EOA negatives. Role ids are hoisted BEFORE expectRevert (the getter would otherwise be the
        // armed "next call").
        address stranger = makeAddr("bm-recipient");
        bytes32 bmMinterRole = bm.MINTER_ROLE();
        vm.prank(deployer);
        vm.expectRevert();
        bm.grantRole(bmMinterRole, stranger); // DEFAULT_ADMIN revoked
        vm.prank(deployer);
        vm.expectRevert();
        bm.mint(stranger, 1e18); // MINTER revoked
        vm.prank(deployer);
        vm.expectRevert();
        bm.setCCIPAdmin(stranger); // DEFAULT_ADMIN revoked

        // Forbidden mechanism: burnmint has NO owner() surface.
        (bool hasOwner,) = RolesProbes._tryAddress(address(bm), "owner()");
        assertFalse(hasOwner, "BurnMintERC20 must expose no owner()");

        // Governance path works, role by role.
        uint256 snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._grantRole(address(bm), bm.MINTER_ROLE(), stranger));
        assertTrue(bm.hasRole(bm.MINTER_ROLE(), stranger), "Safe can grant mint");
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._setCCIPAdmin(address(bm), stranger));
        assertEq(bm.getCCIPAdmin(), stranger, "Safe can set ccipAdmin");
        vm.revertToState(snapshot);
    }

    /// @dev The burnmint leg of the withheld-grant gate test: without the step-A DEFAULT_ADMIN grant,
    ///      the intermediate declaration's [Safe] admin list FAILs (declared-holders-hold, never SKIP).
    function test_handoff_gate_preC_failsWhenSafeGrantMissing_burnmint() public {
        // Step A runs WITHOUT the DEFAULT_ADMIN grant (only the one-step ccipAdmin move).
        new SetCCIPAdminHarness(address(bm), safeAddr).run();
        RolesAuditor.Result memory r = _gate(_bmDeclaration());
        assertGt(r.fails, 0, "the gate must refuse when the Safe's DEFAULT_ADMIN grant is missing");
        assertTrue(vm.contains(r.failedFields, "token.defaultAdmins"), "names the missing admin grant");

        // With the grant landed, the same declaration reconciles clean.
        new TransferTokenAdminHarness(address(bm), safeAddr, false).run();
        assertEq(_gate(_bmDeclaration()).fails, 0, "the gate passes once the grant landed");
    }

    /// @dev The burnmint path is grant-only: the old holder retains the role after the step-A grant.
    function test_handoff_burnmint_default_isGrantOnly() public {
        new TransferTokenAdminHarness(address(bm), safeAddr, false).run();
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, safeAddr), "the new admin is granted DEFAULT_ADMIN");
        assertTrue(
            bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, deployer), "grant-only: the old holder retains DEFAULT_ADMIN"
        );
    }

    function _bmDeclaration() internal view returns (string memory) {
        // Intermediate shape for the grant-model token: the non-enumerable defaultAdmins list declared
        // as [Safe], ccipAdmin already moved (one-step), pool anchored at its live owner (out of this
        // mini-ceremony's scope).
        return string.concat(
            "{\"roles\":{\"token\":{\"address\":",
            _q(address(bm)),
            ",\"type\":\"burnmint\",\"ccipAdmin\":",
            _q(safeAddr),
            ",\"defaultAdmins\":{\"holders\":[",
            _q(safeAddr),
            "],\"complete\":false}},\"pool\":{\"address\":",
            _q(fixturePool),
            ",\"owner\":",
            _q(deployer),
            "}}}"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // factory: the Ownable model
    // ─────────────────────────────────────────────────────────────────────────

    function test_handoff_factory_eoaNegatives() public {
        // Step A: two-step ownership begin + a grant through the Ownable set.
        new TransferTokenAdminHarness(address(factory), safeAddr, false).run();
        assertEq(factory.owner(), deployer, "grant-only: ownership does NOT move in step A");
        assertEq(factory.pendingOwner(), safeAddr, "ownership pending to the Safe");

        // Step B: the Safe accepts (the ExecuteBatch composition path).
        SafeMode._execDirect(safe, CctActions._acceptOwnership(address(factory)));
        assertEq(factory.owner(), safeAddr, "Safe owns the factory token after B");

        // Step C: the Safe revokes the EOA's mint/burn set memberships.
        SafeMode._execDirect(
            safe,
            CctActions._concat(
                CctActions._revokeMintRole(address(factory), deployer),
                CctActions._revokeBurnRole(address(factory), deployer)
            )
        );

        // EOA negatives: every owner-gated call reverts, the mint membership is gone.
        address stranger = makeAddr("factory-recipient");
        vm.prank(deployer);
        vm.expectRevert(bytes("Only callable by owner"));
        factory.transferOwnership(stranger);
        vm.prank(deployer);
        vm.expectRevert(bytes("Only callable by owner"));
        factory.grantMintRole(stranger);
        vm.prank(deployer);
        vm.expectRevert(bytes("Only callable by owner"));
        factory.setCCIPAdmin(stranger);
        vm.prank(deployer);
        vm.expectRevert(bytes("Sender not minter"));
        factory.mint(stranger, 1e18);

        // Governance path works.
        uint256 snapshot = vm.snapshotState();
        SafeMode._execDirect(safe, CctActions._grantMintRole(address(factory), stranger));
        assertTrue(factory.isMinter(stranger), "Safe can grant mint on the Ownable set");
        vm.revertToState(snapshot);

        // The enumerable sets read EOA-free.
        assertFalse(factory.isMinter(deployer), "the EOA left the minters set");
        assertFalse(factory.isBurner(deployer), "the EOA left the burners set");
    }

    /// @dev The factory ACCEPT leg preflights the pending owner: an actor that is not the pending
    ///      owner is refused by name before anything executes.
    function test_handoff_factory_acceptLeg_wrongActor_refuses() public {
        new TransferTokenAdminHarness(address(factory), safeAddr, false).run();
        TransferTokenAdminHarness acceptAsEoa = new TransferTokenAdminHarness(address(factory), safeAddr, true);
        vm.expectRevert(); // the EOA broadcaster is not the pending owner (the Safe is)
        acceptAsEoa.run();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BYO refusals
    // ─────────────────────────────────────────────────────────────────────────

    function test_handoff_byo_refusals() public {
        GrantTokenRoleHarness grant = new GrantTokenRoleHarness(address(byo), "minter", safeAddr);
        vm.expectRevert(
            bytes("byo token: token-internal role moves are not supported (unknown template, complete:false surface)")
        );
        grant.run();

        TransferTokenAdminHarness admin = new TransferTokenAdminHarness(address(byo), safeAddr, false);
        vm.expectRevert(
            bytes(
                "byo token: the top-level admin mechanism of an unknown template is not guessable - move it with the token's own tooling"
            )
        );
        admin.run();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Role×template mismatch (the silent-phantom-success guard)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `burnMintAdmin` exists only on CrossChainToken: on any other template the fallback role id
    ///      would grant a role that admins nothing - refused by name BEFORE any state-changing call.
    function test_tokenRole_roleNotOnTemplate_refusesNamed() public {
        GrantTokenRoleHarness onBurnmint = new GrantTokenRoleHarness(address(bm), "burnMintAdmin", safeAddr);
        vm.expectRevert(
            bytes("ROLE=burnMintAdmin exists only on crosschain (CrossChainToken); this token probes as burnmint")
        );
        onBurnmint.run();
        assertFalse(
            bm.hasRole(RolesProbes.BURN_MINT_ADMIN_ROLE, safeAddr), "no phantom grant may land on the fallback id"
        );

        GrantTokenRoleHarness onFactory = new GrantTokenRoleHarness(address(factory), "burnMintAdmin", safeAddr);
        vm.expectRevert(
            bytes("ROLE=burnMintAdmin exists only on crosschain (CrossChainToken); this token probes as factory")
        );
        onFactory.run();

        RevokeTokenRoleHarness revokeOnBurnmint = new RevokeTokenRoleHarness(address(bm), "burnMintAdmin", deployer);
        vm.expectRevert(
            bytes("ROLE=burnMintAdmin exists only on crosschain (CrossChainToken); this token probes as burnmint")
        );
        revokeOnBurnmint.run();
    }

    function test_tokenRole_invalidRoleName_refusesNamed() public {
        GrantTokenRoleHarness typo = new GrantTokenRoleHarness(address(bm), "minterr", safeAddr);
        vm.expectRevert(bytes("unknown ROLE 'minterr' (minter|burner|burnMintAdmin|defaultAdmin)"));
        typo.run();
    }

    /// @dev ROLE=defaultAdmin is the burnmint step-C revoke primitive (the grant-model DEFAULT_ADMIN
    ///      is multi-holder, so the retired holder's revoke is an ordinary role revoke). Positive leg
    ///      here; the crosschain/factory refusals are in the role-x-template test below.
    function test_tokenRole_defaultAdmin_revokesOnBurnmint() public {
        address retired = makeAddr("retired-admin");
        vm.prank(deployer);
        bm.grantRole(RolesProbes.DEFAULT_ADMIN_ROLE, retired);
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, retired), "seeded holder");

        new RevokeTokenRoleHarness(address(bm), "defaultAdmin", retired).run();
        assertFalse(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, retired), "revoked through the primitive");
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, deployer), "the acting holder keeps its own grant");
    }

    function test_tokenRole_defaultAdmin_refusedOffBurnmint() public {
        RevokeTokenRoleHarness onFactory = new RevokeTokenRoleHarness(address(factory), "defaultAdmin", deployer);
        vm.expectRevert(
            bytes(
                "ROLE=defaultAdmin exists only on burnmint (grant-model AccessControl); this token probes as factory - move its owner with TransferTokenAdmin"
            )
        );
        onFactory.run();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The pending-owner storage probe refuses what it cannot prove
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The probe's self-checks, each refusing with (false, 0) instead of returning a value that
    ///      merely looks like an answer: no typeAndVersion (not a known Chainlink shape); an owner()
    ///      that matches neither of the two storage slots (unknown layout).
    function test_pendingOwnerProbe_refusesUnknownShapes() public {
        (bool okFactory,) = RolesProbes._tryPendingOwner(address(factory));
        assertFalse(okFactory, "no typeAndVersion - refused even though owner() answers");

        MockUnknownLayoutOwnable unknown = new MockUnknownLayoutOwnable();
        (bool okUnknown, address pending) = RolesProbes._tryPendingOwner(address(unknown));
        assertFalse(okUnknown, "owner() matches neither slot - unknown layout refused");
        assertEq(pending, address(0), "a refused probe returns no value");

        (bool okByo,) = RolesProbes._tryPendingOwner(address(byo));
        assertFalse(okByo, "no surface at all - refused");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Default actor/recipient == _executingAccount() + the HOLDER refusal
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Under MODE=safe the grant/set primitives' default recipient is the EXECUTING account
    ///      (the Safe), never the broadcaster (regression guard for 123f714).
    function test_tokenRole_defaultsToExecutingAccount_underSafeMode() public {
        // The Safe must pass the preflight: hand it DEFAULT_ADMIN on the burnmint token first.
        vm.prank(deployer);
        bm.grantRole(RolesProbes.DEFAULT_ADMIN_ROLE, safeAddr);

        GrantTokenRoleSafeCapture grant = new GrantTokenRoleSafeCapture(address(bm), "minter", address(0));
        grant.run();
        assertEq(grant.capturedCount(), 1, "one grant call built");
        (address target,, bytes memory data) = grant.captured(0);
        assertEq(target, address(bm), "targets the token");
        assertEq(
            data,
            abi.encodeCall(IAccessControl.grantRole, (bm.MINTER_ROLE(), safeAddr)),
            "the default grant recipient must be the executing account (the Safe)"
        );

        SetCCIPAdminSafeCapture setAdmin = new SetCCIPAdminSafeCapture(address(bm), address(0));
        setAdmin.run();
        assertEq(setAdmin.capturedCount(), 1, "one setCCIPAdmin call built");
        (,, bytes memory adminData) = setAdmin.captured(0);
        assertEq(
            adminData,
            abi.encodeWithSignature("setCCIPAdmin(address)", safeAddr),
            "the default new ccipAdmin must be the executing account (the Safe)"
        );
    }

    /// @dev RevokeTokenRole has NO default revoke target: a missing HOLDER refuses by name (an
    ///      executing-account default would make the Safe itself the revoke target under MODE=safe).
    function test_revokeTokenRole_missingHolder_refuses() public {
        RevokeTokenRoleHarness noHolder = new RevokeTokenRoleHarness(address(bm), "minter", address(0));
        vm.expectRevert(
            bytes(
                "HOLDER must be set. RevokeTokenRole never defaults the revoke target: under MODE=safe the default executing account is the Safe itself, and revoking the recipient is the inversion the handoff forbids."
            )
        );
        noHolder.run();
    }

    /// @dev Self-revocation is refused: HOLDER == the executing account can strand the token with
    ///      zero working admins in one mis-set command (e.g. the step-C line run in EOA mode with
    ///      HOLDER pointing at the broadcaster), and no ceremony step revokes from the actor.
    function test_revokeTokenRole_selfRevoke_refuses() public {
        RevokeTokenRoleHarness selfTarget = new RevokeTokenRoleHarness(address(bm), "defaultAdmin", deployer);
        vm.expectRevert(
            bytes(
                "HOLDER is the executing account itself. Self-revocation is refused: revoking your own DEFAULT_ADMIN_ROLE (or your own mint/burn authority) can strand the token with no working admin, and no ceremony step revokes from the actor."
            )
        );
        selfTarget.run();
        assertTrue(bm.hasRole(RolesProbes.DEFAULT_ADMIN_ROLE, deployer), "the actor's admin survives");
    }

    /// @dev The v1-LR rebalancer row: the one-step setRebalancer move to the Safe, the auditor's
    ///      rebalancer rung reconciling it, and the drift FAIL naming the field.
    function test_handoff_v1Rebalancer_moveAndReconcile() public {
        MockV1LockReleasePool lr = new MockV1LockReleasePool();
        _exec(address(this), CctActions._setRebalancer(address(lr), safeAddr));
        assertEq(lr.getRebalancer(), safeAddr, "rebalancer moved to the Safe");

        string memory doc = string.concat(
            "{\"roles\":{\"token\":{\"address\":",
            _q(address(bm)),
            ",\"type\":\"burnmint\"},\"pool\":{\"address\":",
            _q(address(lr)),
            "},\"rebalancer\":",
            _q(safeAddr),
            "}}"
        );
        assertEq(_gate(doc).fails, 0, "the declared rebalancer reconciles");

        string memory drifted = vm.replace(doc, vm.toString(safeAddr), vm.toString(makeAddr("rogue-rebalancer")));
        RolesAuditor.Result memory r = _gate(drifted);
        assertGt(r.fails, 0, "a drifted rebalancer FAILs");
        assertTrue(vm.contains(r.failedFields, "rebalancer"), "the FAIL names the rebalancer field");
    }
}

/// @title BurnMintERC677TemplatesForkTest - proves the REAL `BurnMintERC677`
/// (chainlink contracts v1.5.0, an `OwnerIsCreator`/`ConfirmedOwner` two-step-owner token with an
/// owner-gated minter/burner EnumerableSet, no OZ AccessControl and no `getCCIPAdmin`) is a supported
/// `factory`-template token. It classifies as `FactoryBurnMintERC20`, moves its top-level admin through
/// the `TransferTokenAdmin` transfer/accept legs (`transferOwnership`/`acceptOwnership`), grants and
/// revokes mint/burn through `GrantTokenRole`/`RevokeTokenRole`, and refuses `SetCCIPAdmin` by name.
/// Distinct from the vendored `FactoryBurnMintERC20`: `ConfirmedOwner` exposes NO `pendingOwner()`
/// getter and NO `typeAndVersion()`, so the storage pending-owner probe refuses it and the pending slot
/// is proven behaviorally instead.
contract BurnMintERC677TemplatesForkTest is RolesHandoffBase {
    BurnMintERC677 internal token;

    function setUp() public override {
        super.setUp();
        deployer = _scriptBroadcaster();
        _setUpSafe();
        vm.startPrank(deployer);
        token = new BurnMintERC677("Handoff ERC677", "H677", 18, 0);
        token.grantMintRole(deployer);
        token.grantBurnRole(deployer);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Template classification
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The whole basis of factory support: the real BurnMintERC677 probes as the factory template
    ///      (owner() answers, no AccessControl surface) and lacks the Chainlink-shape markers the
    ///      storage pending-owner probe needs, so that probe honestly refuses rather than misreads.
    function test_erc677_detectsAsFactory() public view {
        assertEq(
            uint256(RolesProbes._detectTemplate(address(token))),
            uint256(RolesProbes.TokenTemplate.FactoryBurnMintERC20),
            "BurnMintERC677 must classify as the factory template"
        );
        assertEq(RolesProbes._templateName(RolesProbes._detectTemplate(address(token))), "factory", "templateName");

        (bool hasOwner,) = RolesProbes._tryAddress(address(token), "owner()");
        assertTrue(hasOwner, "owner() answers");
        (bool hasAcl,) = RolesProbes._tryBytes32(address(token), "DEFAULT_ADMIN_ROLE()");
        assertFalse(hasAcl, "no OZ AccessControl surface");
        (bool hasDefaultAdmin,) = RolesProbes._tryAddress(address(token), "defaultAdmin()");
        assertFalse(hasDefaultAdmin, "no AccessControlDefaultAdminRules surface");
        (bool hasCcipAdmin,) = RolesProbes._tryAddress(address(token), "getCCIPAdmin()");
        assertFalse(hasCcipAdmin, "no getCCIPAdmin slot");

        // ConfirmedOwner exposes no typeAndVersion, so the storage pending-owner probe refuses it.
        (bool okProbe,) = RolesProbes._tryPendingOwner(address(token));
        assertFalse(okProbe, "the storage pending-owner probe refuses a token without typeAndVersion");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TransferTokenAdmin: the two-step top-level admin handoff
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Transfer leg (step A) moves nothing yet: owner() stays the EOA, and the pending slot is set
    ///      to the Safe. The accept leg (the same script calldata, run by the Safe as the pending owner)
    ///      moves owner() to the Safe and clears the pending slot (a re-accept then reverts).
    function test_erc677_transferLeg_thenAccept_movesOwner() public {
        new TransferTokenAdminHarness(address(token), safeAddr, false).run();
        assertEq(token.owner(), deployer, "grant-only: ownership does NOT move in the transfer leg");

        // The pending slot is set to the Safe: proven behaviorally because the Safe can accept.
        SafeMode._execDirect(safe, CctActions._acceptOwnership(address(token)));
        assertEq(token.owner(), safeAddr, "the accept leg moved owner() to the Safe");

        // The pending slot was cleared by the accept: a second accept reverts.
        vm.prank(safeAddr);
        vm.expectRevert(bytes("Must be proposed owner"));
        token.acceptOwnership();
    }

    /// @dev The accept leg driven through the script harness (`ACCEPT=1`) to SUCCESS: a token whose
    ///      pending owner is the broadcaster is accepted by the harness run, moving owner() to it. The
    ///      transfer that set the pending is a raw two-step call because the harness always broadcasts as
    ///      one account (the transfer script leg is covered as the EOA above; here the focus is the
    ///      accept leg's own code path completing).
    function test_erc677_acceptLeg_viaHarness_success() public {
        address seedOwner = makeAddr("erc677-seed-owner");
        vm.prank(seedOwner);
        BurnMintERC677 seeded = new BurnMintERC677("Seeded 677", "SD677", 18, 0);
        vm.prank(seedOwner);
        seeded.transferOwnership(deployer); // pending owner == the harness broadcaster

        new TransferTokenAdminHarness(address(seeded), address(0), true).run();
        assertEq(seeded.owner(), deployer, "the accept leg harness moved owner() to the pending owner");

        // Pending cleared: another accept by the same actor reverts.
        vm.prank(deployer);
        vm.expectRevert(bytes("Must be proposed owner"));
        seeded.acceptOwnership();
    }

    /// @dev The accept leg refuses a non-pending actor. BurnMintERC677 has no `pendingOwner()` getter,
    ///      so the script's pending-owner preflight is skipped and the guard falls to the token's own
    ///      `acceptOwnership` (`Must be proposed owner`) - the move still cannot happen.
    function test_erc677_acceptLeg_wrongActor_refuses() public {
        new TransferTokenAdminHarness(address(token), safeAddr, false).run();
        TransferTokenAdminHarness acceptAsEoa = new TransferTokenAdminHarness(address(token), safeAddr, true);
        vm.expectRevert(bytes("Must be proposed owner")); // the EOA broadcaster is not the pending owner
        acceptAsEoa.run();
        assertEq(token.owner(), deployer, "a refused accept leaves owner() unmoved");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GrantTokenRole / RevokeTokenRole: the Ownable minter/burner sets
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The factory branch of GrantTokenRole calls the Ownable `grantMintRole`/`grantBurnRole`. A
    ///      granted minter appears in `getMinters()`/`isMinter()` and can mint; RevokeTokenRole removes
    ///      it again.
    function test_erc677_grantAndRevoke_minterBurner() public {
        address minter = makeAddr("erc677-minter");
        address burner = makeAddr("erc677-burner");

        new GrantTokenRoleHarness(address(token), "minter", minter).run();
        new GrantTokenRoleHarness(address(token), "burner", burner).run();

        assertTrue(token.isMinter(minter), "the granted minter is in the minter set");
        assertTrue(token.isBurner(burner), "the granted burner is in the burner set");
        assertTrue(RolesProbes._contains(token.getMinters(), minter), "getMinters() enumerates the new minter");
        assertTrue(RolesProbes._contains(token.getBurners(), burner), "getBurners() enumerates the new burner");

        // The granted minter can mint; a non-minter cannot.
        address recipient = makeAddr("erc677-recipient");
        vm.prank(minter);
        token.mint(recipient, 1e18);
        assertEq(token.balanceOf(recipient), 1e18, "the granted minter minted");
        vm.prank(makeAddr("erc677-stranger"));
        vm.expectRevert();
        token.mint(recipient, 1e18);

        // RevokeTokenRole removes the minter from the Ownable set.
        new RevokeTokenRoleHarness(address(token), "minter", minter).run();
        assertFalse(token.isMinter(minter), "RevokeTokenRole removed the minter");
        assertFalse(RolesProbes._contains(token.getMinters(), minter), "getMinters() no longer enumerates it");
    }

    /// @dev The default grant recipient is the executing account: a HOLDER-less grant lands on the owner.
    function test_erc677_grant_defaultsToExecutingAccount() public {
        address owner_ = token.owner();
        // Start from a token with no minter set so the default-recipient grant is observable.
        vm.prank(deployer);
        BurnMintERC677 fresh = new BurnMintERC677("Fresh 677", "FR677", 18, 0);
        assertFalse(fresh.isMinter(owner_), "precondition: owner is not yet a minter");
        new GrantTokenRoleHarness(address(fresh), "minter", address(0)).run();
        assertTrue(fresh.isMinter(deployer), "the default grant recipient is the executing account");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SetCCIPAdmin: refused by name (no getCCIPAdmin slot)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev BurnMintERC677 has no `getCCIPAdmin()`, so SetCCIPAdmin refuses by name before any call.
    function test_erc677_setCcipAdmin_refusesNoSlot() public {
        SetCCIPAdminHarness setAdmin = new SetCCIPAdminHarness(address(token), safeAddr);
        vm.expectRevert(bytes("Token exposes no getCCIPAdmin() - it has no CCIP admin slot to set."));
        setAdmin.run();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Role x template mismatch: admin roles do not exist on factory
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `burnMintAdmin` (crosschain-only) and `defaultAdmin` (burnmint-only) are refused by name on
    ///      the factory template, so no phantom grant lands.
    function test_erc677_adminRoles_refusedOnFactory() public {
        GrantTokenRoleHarness bmAdmin = new GrantTokenRoleHarness(address(token), "burnMintAdmin", safeAddr);
        vm.expectRevert(
            bytes("ROLE=burnMintAdmin exists only on crosschain (CrossChainToken); this token probes as factory")
        );
        bmAdmin.run();

        RevokeTokenRoleHarness defaultAdmin = new RevokeTokenRoleHarness(address(token), "defaultAdmin", deployer);
        vm.expectRevert(
            bytes(
                "ROLE=defaultAdmin exists only on burnmint (grant-model AccessControl); this token probes as factory - move its owner with TransferTokenAdmin"
            )
        );
        defaultAdmin.run();
    }
}
