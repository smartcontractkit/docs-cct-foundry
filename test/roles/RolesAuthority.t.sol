// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

import {RolesProbes} from "../../src/roles/RolesProbes.sol";
import {RolesSnapshot} from "../../src/roles/RolesSnapshot.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";

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
/// @notice Acceptance bar for the READ-ONLY reconcile engine of PR 3.5 (`roles{}` durable store):
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

    address internal fixtureToken;
    address internal fixturePool;
    string internal baseJson;

    function setUp() public override {
        super.setUp();
        snap = new RolesSnapshot();
        auditor = new RolesAuditor();
        (fixtureToken, fixturePool) = deployTokenAndPoolFixture();
        // Anchor the snapshot/audit on the fixture addresses (the gitignored registry is racy under
        // parallel suites, so the fixture computes the addresses deterministically and passes them in).
        vm.setEnv("TOKEN", vm.toString(fixtureToken));
        vm.setEnv("TOKEN_POOL", vm.toString(fixturePool));
        baseJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");
    }

    /// @dev Wrap a built `roles{}` object as a full config document the auditor can read.
    function _wrap(string memory rolesJson) internal pure returns (string memory) {
        return string.concat("{\"roles\":", rolesJson, "}");
    }

    /// @dev Point a `build()` at a specific token via the DECLARED-roles path (`_resolveProject`
    /// prefers `.roles.token.address` over the `TOKEN` env). `vm.setEnv` mutates the OS-process-global
    /// env, which forge 1.7.x shares across its parallel test-case executor — a mid-test `setEnv("TOKEN")`
    /// races any concurrent test that reads it. Injecting the address into the LOCAL config string keeps
    /// resolution test-local and order/thread-independent, while preserving `baseJson`'s `.ccip.*`
    /// (the TAR fallback reads `.ccip.tokenAdminRegistry`).
    function _withTokenAddress(string memory baseCfg, address token) internal pure returns (string memory) {
        bytes memory b = bytes(baseCfg);
        require(b.length > 0 && b[0] == "{", "config must be a JSON object");
        bytes memory rest = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; i++) {
            rest[i - 1] = b[i];
        }
        return string.concat("{\"roles\":{\"token\":{\"address\":\"", vm.toString(token), "\"}},", string(rest));
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
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);

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
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "a fresh snapshot must reconcile clean against the same chain");
        assertGt(r.passes, 3, "the token/pool/tar rungs ran");
    }

    // ---------------------------------------------------------------- induced drift

    function test_inducedDrift_failsNamingField() public {
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
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
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
        // declare the wrong template (factory) for the crosschain fixture
        string memory mutated = vm.replace(_wrap(roles), "\"crosschain\"", "\"factory\"");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", mutated);
        assertGt(r.fails, 0, "a declared type contradicting the surface must FAIL");
        assertTrue(vm.contains(r.failedFields, "token.type"), "the FAIL must name token.type");
    }

    // ---------------------------------------------------------------- honesty WARNs (non-enumerable)

    function test_freshSnapshot_completeFalse_warns() public {
        // no SCAN_FROM_BLOCK in the fork suite -> minters/burners are candidate-seeded, complete:false
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "declared-holders-hold still passes");
        assertGt(r.warns, 0, "a non-enumerable complete:false list must WARN (additive grants unverified)");
    }

    function test_completeTrue_nonEnumerable_stillWarns() public {
        // a complete:true marker on a non-enumerable token is a PAST snapshot proof, not re-verifiable
        // by read now -> the auditor must WARN, never report a silent CLEAN.
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
        string memory mutated = vm.replace(_wrap(roles), "\"complete\":false", "\"complete\":true");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", mutated);
        assertEq(r.fails, 0, "declared holders still hold");
        assertGt(r.warns, 0, "complete:true on a non-enumerable token must still WARN (not re-verifiable)");
    }

    // ---------------------------------------------------------------- burnmint snapshot + reconcile

    function test_burnmint_snapshotAndReconcile() public {
        BurnMintERC20 bm = new BurnMintERC20("Burn Mint", "BM", 18, 0, 0);
        // Point the snapshot at the burnmint token via the declared-roles path (NOT the global TOKEN
        // env) so this test does not race concurrent test-cases under forge's parallel executor.
        string memory roles = snap.build("ethereum-testnet-sepolia", _withTokenAddress(baseJson, address(bm)));
        assertEq(vm.parseJsonString(roles, ".token.type"), "burnmint", "detected as burnmint");
        // this test's deployer (the test contract) holds DEFAULT_ADMIN_ROLE -> declared + reconciles
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "a fresh burnmint snapshot must reconcile clean");
        assertTrue(bm.hasRole(bytes32(0), address(this)), "test contract holds DEFAULT_ADMIN_ROLE");
    }

    // ---------------------------------------------------------------- absent governance -> SKIP

    function test_absentGovernance_skips_notFails() public {
        // the fixture pool owner is the deployer EOA (no Safe/timelock), so no governance{} block
        string memory roles = snap.build("ethereum-testnet-sepolia", baseJson);
        assertFalse(vm.keyExistsJson(_wrap(roles), ".roles.governance"), "EOA fixture emits no governance{} block");
        RolesAuditor.Result memory r = auditor.auditJson("ethereum-testnet-sepolia", _wrap(roles));
        assertEq(r.fails, 0, "an EOA-only chain must not FAIL");
        assertTrue(vm.contains(r.skippedBlocks, "governance"), "governance{} absence is a SKIP");
    }
}
