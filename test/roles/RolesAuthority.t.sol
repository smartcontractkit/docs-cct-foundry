// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

import {RolesProbes} from "../../src/roles/RolesProbes.sol";
import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @dev Minimal Ownable surface — the `FactoryBurnMintERC20` DETECTION shape (owner(), no
/// AccessControl). Detection keys on `owner()` answering while `DEFAULT_ADMIN_ROLE()` does not; a
/// faithful stand-in for template detection without vendoring the factory token.
contract MockOwnableToken {
    address public owner;

    constructor() {
        owner = msg.sender;
    }
}

/// @dev A plain contract with none of the admin surfaces — the BYO/unknown detection shape.
contract MockPlainToken {
    uint256 public x;
}

/// @title RolesAuthorityTest
/// @notice Acceptance bar for the READ-ONLY reconcile engine (`roles{}` durable store):
///   - the four-template dispatch detects `crosschain`/`burnmint`/`factory`/`byo` from the live
///     surface, and `templateFromName` round-trips (and rejects a typo);
///   - `RolesSnapshot` reproduces direct on-chain reads for the repo's own CrossChainToken + pool
///     fixture (snapshot fidelity);
///   - the freshly snapshotted declaration reconciles CLEAN (`RolesAuditor.fails == 0`);
///   - a mutated declared holder FAILs naming the exact field (induced drift);
///   - an EOA-owned pool (no Safe/timelock) SKIPs the `governance{}` block, never FAILs;
///   - a non-enumerable AccessControl token's mint list is marked `complete:false` (the honesty rule).
/// The live-testnet proof (`snapshot-chain` then `roles-check` against a real deployment, plus a
/// `SCAN_FROM_BLOCK` event-scan run) is the cct-tester's job — this suite pins the mechanism on a fork.
contract RolesAuthorityTest is BaseForkTest {
    RolesSnapshot internal snap;
    RolesAuditor internal auditor;

    // A scratch selectorName used ONLY by the no-leak regression test to plant a poisoned on-disk
    // project file (zz-scratch-*, gitignored; cleaned in setUp).
    string internal constant NOLEAK_SEL = "zz-scratch-rolesauth-noleak";

    address internal fixtureToken;
    address internal fixturePool;
    string internal baseJson;

    function setUp() public override {
        super.setUp();
        snap = new RolesSnapshot();
        auditor = new RolesAuditor();
        (fixtureToken, fixturePool) = deployTokenAndPoolFixture();
        baseJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
        _clean();
    }

    /// @dev Revert-safe hygiene: removes any leftover poisoned project file so the no-leak test
    /// always starts clean (a gitignored leak is invisible to `git status`). The setUp() call is the
    /// guarantee; the end-of-test call keeps a green run residue-free.
    function _clean() private {
        string memory poisonPath = ProjectStore.path(NOLEAK_SEL);
        if (vm.exists(poisonPath)) vm.removeFile(poisonPath);
    }

    /// @dev Wrap a built `roles{}` object as a project document the auditor can read.
    function _wrap(string memory rolesJson) internal pure returns (string memory) {
        return string.concat("{\"roles\":", rolesJson, "}");
    }

    /// @dev The EXPLICIT `projectJson` a `build()` resolves the fixture token+pool from — passed as the
    /// 3rd `build` arg so resolution is fully test-local and NEVER reads `project/<name>.json` off disk.
    /// This is the isolation seam: no `TOKEN`/`TOKEN_POOL` process-global env (racy under forge's parallel
    /// executor) and no real project file can influence the fixture snapshot.
    function _fixtureProject(address token, address pool) internal pure returns (string memory) {
        return string.concat(
            "{\"roles\":{\"token\":{\"address\":\"",
            vm.toString(token),
            "\"},\"pool\":{\"address\":\"",
            vm.toString(pool),
            "\"}}}"
        );
    }

    // ---------------------------------------------------------------- template dispatch

    function test_detectTemplate_crosschain() public view {
        assertEq(
            uint256(RolesProbes.detectTemplate(fixtureToken)),
            uint256(RolesProbes.TokenTemplate.CrossChainToken),
            "CrossChainToken must probe as crosschain"
        );
    }

    function test_detectTemplate_burnmint() public {
        BurnMintERC20 bm = new BurnMintERC20("Burn Mint", "BM", 18, 0, 0);
        assertEq(
            uint256(RolesProbes.detectTemplate(address(bm))),
            uint256(RolesProbes.TokenTemplate.BurnMintERC20),
            "plain-AccessControl BurnMintERC20 must probe as burnmint (no defaultAdmin())"
        );
    }

    function test_detectTemplate_factory() public {
        MockOwnableToken t = new MockOwnableToken();
        assertEq(
            uint256(RolesProbes.detectTemplate(address(t))),
            uint256(RolesProbes.TokenTemplate.FactoryBurnMintERC20),
            "Ownable token must probe as factory"
        );
    }

    function test_detectTemplate_byo() public {
        MockPlainToken t = new MockPlainToken();
        assertEq(
            uint256(RolesProbes.detectTemplate(address(t))),
            uint256(RolesProbes.TokenTemplate.BYO),
            "token with no admin surface must probe as byo"
        );
    }

    function test_templateFromName_roundTrips() public pure {
        string[4] memory names = ["crosschain", "burnmint", "factory", "byo"];
        for (uint256 i = 0; i < names.length; i++) {
            assertEq(
                RolesProbes.templateName(RolesProbes.templateFromName(names[i])),
                names[i],
                "template name must round-trip"
            );
        }
    }

    function test_templateFromName_rejectsTypo() public {
        vm.expectRevert();
        this.parseTemplate("crosschian");
    }

    function parseTemplate(string memory name) external pure returns (RolesProbes.TokenTemplate) {
        return RolesProbes.templateFromName(name);
    }

    // ---------------------------------------------------------------- snapshot fidelity

    function test_snapshot_matchesDirectReads() public {
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));

        assertEq(vm.parseJsonString(roles, ".token.type"), "crosschain", "token.type");
        assertEq(vm.parseJsonAddress(roles, ".token.address"), fixtureToken, "token.address");
        assertEq(vm.parseJsonAddress(roles, ".pool.address"), fixturePool, "pool.address");

        (bool okOwner, address liveOwner) = RolesProbes.tryAddress(fixturePool, "owner()");
        assertTrue(okOwner, "pool exposes owner()");
        assertEq(vm.parseJsonAddress(roles, ".pool.owner"), liveOwner, "pool.owner");

        (bool okDa, address liveDa) = RolesProbes.tryAddress(fixtureToken, "defaultAdmin()");
        assertTrue(okDa, "token exposes defaultAdmin()");
        assertEq(vm.parseJsonAddress(roles, ".token.defaultAdmin"), liveDa, "token.defaultAdmin");

        (bool okCa, address liveCa) = RolesProbes.tryAddress(fixtureToken, "getCCIPAdmin()");
        assertTrue(okCa, "token exposes getCCIPAdmin()");
        assertEq(vm.parseJsonAddress(roles, ".token.ccipAdmin"), liveCa, "token.ccipAdmin");

        // CrossChainToken is AccessControlDefaultAdminRules (NOT Enumerable) -> minters not enumerable
        // -> the honesty marker must be complete:false without a SCAN_FROM_BLOCK run.
        assertFalse(vm.parseJsonBool(roles, ".token.minters.complete"), "minters must be marked complete:false");
    }

    // ---------------------------------------------------------------- clean reconcile

    function test_auditFreshSnapshot_reconcilesClean() public {
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "a fresh snapshot must reconcile clean against the same chain");
        assertGt(r.passes, 3, "the token/pool/tar rungs ran");
    }

    // ---------------------------------------------------------------- induced drift

    function test_inducedDrift_failsNamingField() public {
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        (bool okOwner, address realOwner) = RolesProbes.tryAddress(fixturePool, "owner()");
        assertTrue(okOwner, "pool exposes owner()");
        // mutate the declared pool.owner in-memory (never a real file) to an intruder
        string memory mutated = vm.replace(_wrap(roles), vm.toString(realOwner), vm.toString(makeAddr("intruder")));
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", mutated);
        assertGt(r.fails, 0, "a mutated declared owner must FAIL");
        assertTrue(vm.contains(r.failedFields, "pool.owner"), "the FAIL must name pool.owner");
    }

    // ---------------------------------------------------------------- type-mismatch FAIL

    function test_typeMismatch_failsNamingTokenType() public {
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        // declare the wrong template (factory) for the crosschain fixture
        string memory mutated = vm.replace(_wrap(roles), "\"crosschain\"", "\"factory\"");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", mutated);
        assertGt(r.fails, 0, "a declared type contradicting the surface must FAIL");
        assertTrue(vm.contains(r.failedFields, "token.type"), "the FAIL must name token.type");
    }

    // ---------------------------------------------------------------- honesty WARNs (non-enumerable)

    function test_freshSnapshot_completeFalse_warns() public {
        // no SCAN_FROM_BLOCK in the fork suite -> minters/burners are candidate-seeded, complete:false
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "declared-holders-hold still passes");
        assertGt(r.warns, 0, "a non-enumerable complete:false list must WARN (additive grants unverified)");
    }

    function test_completeTrue_nonEnumerable_stillWarns() public {
        // a complete:true marker on a non-enumerable token is a PAST snapshot proof, not re-verifiable
        // by read now -> the auditor must WARN, never report a silent CLEAN.
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        string memory mutated = vm.replace(_wrap(roles), "\"complete\":false", "\"complete\":true");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", mutated);
        assertEq(r.fails, 0, "declared holders still hold");
        assertGt(r.warns, 0, "complete:true on a non-enumerable token must still WARN (not re-verifiable)");
    }

    // ---------------------------------------------------------------- burnmint snapshot + reconcile

    function test_burnmint_snapshotAndReconcile() public {
        BurnMintERC20 bm = new BurnMintERC20("Burn Mint", "BM", 18, 0, 0);
        // Point the snapshot at the burnmint token via the EXPLICIT projectJson declared-roles path (NOT
        // any global env) so this test does not race concurrent test-cases under forge's parallel
        // executor. The fixture pool (owned by this deployer EOA) reconciles clean.
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(address(bm), fixturePool));
        assertEq(vm.parseJsonString(roles, ".token.type"), "burnmint", "detected as burnmint");
        // this test's deployer (the test contract) holds DEFAULT_ADMIN_ROLE -> declared + reconciles
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "a fresh burnmint snapshot must reconcile clean");
        assertTrue(bm.hasRole(bytes32(0), address(this)), "test contract holds DEFAULT_ADMIN_ROLE");
    }

    // ---------------------------------------------------------------- absent governance -> SKIP

    function test_absentGovernance_skips_notFails() public {
        // the fixture pool owner is the deployer EOA (no Safe/timelock), so no governance{} block
        string memory roles =
            snap.build("ethereum-testnet-sepolia", baseJson, _fixtureProject(fixtureToken, fixturePool));
        assertFalse(vm.keyExistsJson(_wrap(roles), ".roles.governance"), "EOA fixture emits no governance{} block");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "an EOA-only chain must not FAIL");
        assertTrue(vm.contains(r.skippedBlocks, "governance"), "governance{} absence is a SKIP");
    }

    // ---------------------------------------------------------------- NEGATIVE: on-disk project no-leak
    //
    // `roles{}` lives in the gitignored `project/<selectorName>.json`, and `build`/`auditJson` take the
    // declaration as an EXPLICIT argument (never a disk read), so a populated real project file for the
    // same selectorName CANNOT leak into a fixture test. This proves it: plant a poisoned on-disk project
    // file, then prove the explicit-arg snapshot + audit ignore it entirely.
    function test_realProjectFileDoesNotLeakIntoFixtureRolesTest() public {
        address poisonToken = makeAddr("poison-real-project-token");
        string memory poisoned = string.concat(
            "{\"addresses\":{\"active\":{},\"deployments\":{}},\"lanes\":{},",
            "\"roles\":{\"token\":{\"type\":\"crosschain\",\"address\":\"",
            vm.toString(poisonToken),
            "\"}},\"schema\":3}"
        );
        // Plant the poisoned file on disk at project/<NOLEAK_SEL>.json (cleaned in setUp).
        vm.writeFile(ProjectStore.path(NOLEAK_SEL), poisoned);
        assertTrue(vm.exists(ProjectStore.path(NOLEAK_SEL)), "precondition: poisoned project file is on disk");

        // build() is given the FIXTURE declaration explicitly (3rd arg). If it ever read the on-disk
        // project file for NOLEAK_SEL (the upstream bug) it would resolve the poison token instead.
        string memory roles = snap.build(NOLEAK_SEL, baseJson, _fixtureProject(fixtureToken, fixturePool));
        assertEq(
            vm.parseJsonAddress(roles, ".token.address"),
            fixtureToken,
            "snapshot resolved the fixture token (the on-disk project file did NOT leak)"
        );
        assertTrue(
            vm.parseJsonAddress(roles, ".token.address") != poisonToken,
            "the poisoned on-disk project token leaked into the fixture snapshot"
        );

        // auditJson() likewise reconciles the EXPLICIT fixture declaration (no disk read): clean, even
        // though a poisoned real project file sits on disk for the same selectorName.
        RolesAuditor.Result memory r = auditor.auditJson(NOLEAK_SEL, _wrap(roles));
        assertEq(r.fails, 0, "explicit-declaration audit must ignore the poisoned on-disk project file");
        _clean();
    }
}
