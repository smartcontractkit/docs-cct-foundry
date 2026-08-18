// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {DeploymentRecorder} from "../../script/utils/DeploymentRecorder.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @dev External wrapper so `vm.expectRevert` can observe the library's revert (internal library
/// calls are inlined into the test frame otherwise), and so the tests drive the deterministic cores
/// directly (the context-aware `guard`/`record` no-op under `forge test`, which is exactly the
/// inertness `BaseForkTest` relies on - see `test_ContextAware_NoRegistryMutationUnderForgeTest`).
contract GuardHarness {
    /// @dev The plain refusal path, with the has-code evidence supplied as true rather than read.
    function guardForced(string memory sel, string memory name, bool forced) external {
        RegistryWriter._guardRedeploy(sel, name, forced, RegistryWriter._readDeployment(sel, name), true);
    }

    function guardEnv(string memory sel, string memory name) external {
        RegistryWriter._guardRedeploy(sel, name);
    }

    /// @dev The core with chain evidence supplied, so a test picks the branch outright.
    function guardWithChainEvidence(string memory sel, string memory name, bool forced, bool recordedHasCode) external {
        RegistryWriter._guardRedeploy(sel, name, forced, RegistryWriter._readDeployment(sel, name), recordedHasCode);
    }

    /// @dev The wrapper that reads code presence itself - the only way to test that read.
    function guardAgainstChain(string memory sel, string memory name, bool forced) external {
        RegistryWriter._guardRedeployAgainstChain(sel, name, forced);
    }

    function recordDeterministic(string memory sel, string memory role, string memory name, address addr) external {
        RegistryWriter._recordDeterministic(sel, role, name, addr);
    }

    function record(string memory sel, string memory role, string memory name, address addr) external {
        RegistryWriter._record(sel, role, name, addr);
    }

    function guard(string memory sel, string memory name) external {
        RegistryWriter._guard(sel, name);
    }

    function setActive(string memory sel, string memory role, address addr) external {
        RegistryWriter._setActive(sel, role, addr);
    }

    function setDeployment(string memory sel, string memory name, address addr) external {
        RegistryWriter._setDeployment(sel, name, addr);
    }

    function read(string memory sel, string memory role) external view returns (address) {
        return RegistryWriter._read(sel, role);
    }

    function readDeployment(string memory sel, string memory name) external view returns (address) {
        return RegistryWriter._readDeployment(sel, name);
    }
}

/// @notice Schema-3 project store (`addresses.active` role pointers + named `addresses.deployments`)
/// and its single-writer record + redeploy guard. Each test uses its OWN throwaway
/// `project/zz-scratch-registryguard-<test>.json` (a `zz-scratch-*` basename, gitignored, cleaned in
/// `setUp`): forge runs tests in parallel and no real chain's project file is ever touched. The
/// deploy-time keys are composed through `DeploymentRecorder` so the tests key exactly as the scripts do.
contract RegistryGuardTest is Test {
    // A BurnMint and a LockRelease pool for the same token, and two versions of the BurnMint pool.
    string internal constant SYMBOL = "BnM-T";
    address internal constant TOKEN = address(0x1111111111111111111111111111111111111111);
    address internal constant PHANTOM = address(0x9999999999999999999999999999999999999999);
    address internal constant POOL_BURNMINT = address(0x2222222222222222222222222222222222222222);
    address internal constant POOL_LOCKRELEASE = address(0x3333333333333333333333333333333333333333);
    address internal constant POOL_V161 = address(0x4444444444444444444444444444444444444444);
    address internal constant POOL_V200 = address(0x5555555555555555555555555555555555555555);
    address internal constant HOOKS_A = address(0x6666666666666666666666666666666666666666);
    address internal constant HOOKS_B = address(0x7777777777777777777777777777777777777777);

    // One unique scratch selectorName per test (shared basenames race under seed-if-absent).
    string internal constant SEL_CROSSPOOL = "zz-scratch-registryguard-crosspool";
    string internal constant SEL_TWOVER = "zz-scratch-registryguard-twover";
    string internal constant SEL_REDEPLOY = "zz-scratch-registryguard-redeploy";
    string internal constant SEL_HOOKS = "zz-scratch-registryguard-hooks";
    string internal constant SEL_ONECALL = "zz-scratch-registryguard-onecall";
    string internal constant SEL_CTXA = "zz-scratch-registryguard-ctxa";
    string internal constant SEL_CTXB = "zz-scratch-registryguard-ctxb";
    string internal constant SEL_ENVFORCE = "zz-scratch-registryguard-envforce";
    string internal constant SEL_PHANTOM = "zz-scratch-registryguard-phantom";
    string internal constant SEL_REAL = "zz-scratch-registryguard-real";
    string internal constant SEL_PHANTOMFORCE = "zz-scratch-registryguard-phantomforce";
    string internal constant SEL_FIRSTRUN = "zz-scratch-registryguard-firstrun";
    string internal constant SEL_WIRING = "zz-scratch-registryguard-wiring";

    GuardHarness internal harness;

    function setUp() public {
        harness = new GuardHarness();
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[13] memory sels = [
            SEL_CROSSPOOL,
            SEL_TWOVER,
            SEL_REDEPLOY,
            SEL_HOOKS,
            SEL_ONECALL,
            SEL_CTXA,
            SEL_CTXB,
            SEL_ENVFORCE,
            SEL_PHANTOM,
            SEL_REAL,
            SEL_PHANTOMFORCE,
            SEL_FIRSTRUN,
            SEL_WIRING
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            ProjectScratch.clean(sels[i]);
        }
    }

    // (1) No cross-pool-type collision: a BurnMint and a LockRelease pool for the SAME token on one
    //     chain both record and both resolve; neither clobbers the other's deployments entry.
    function test_CrossPoolType_BothResolvable_NoClobber() public {
        string memory sel = SEL_CROSSPOOL;
        string memory bmName = DeploymentRecorder._poolName(SYMBOL, "BurnMint");
        string memory lrName = DeploymentRecorder._poolName(SYMBOL, "LockRelease");

        harness.recordDeterministic(sel, "tokenPool", bmName, POOL_BURNMINT);
        harness.recordDeterministic(sel, "tokenPool", lrName, POOL_LOCKRELEASE);

        assertEq(harness.readDeployment(sel, bmName), POOL_BURNMINT, "BurnMint pool resolvable");
        assertEq(harness.readDeployment(sel, lrName), POOL_LOCKRELEASE, "LockRelease pool resolvable");
        // active.tokenPool mirrors the most-recently-recorded pool.
        assertEq(harness.read(sel, "tokenPool"), POOL_LOCKRELEASE, "active.tokenPool is newest");
        ProjectScratch.clean(SEL_CROSSPOOL);
    }

    // (2) DATA LAYER holds two versioned entries: because the deployments key carries the pool type +
    //     version, two version keys (1.6.1, 2.0.0) coexist without tripping the guard, both addresses
    //     resolve via readDeployment, and active.tokenPool mirrors the newest write. This proves ONLY
    //     the storage layer - it is NOT a migration flow reachable through the deploy scripts:
    //     `DeploymentRecorder.POOL_VERSION` is hardcoded "2.0.0", so the scripts only ever emit the
    //     _2.0.0 key. The 1.6.1 key below is hand-injected to exercise the data structure directly.
    function test_TwoVersionedEntries_CoexistInRegistryDataLayer() public {
        string memory sel = SEL_TWOVER;
        // Hand-inject a 1.6.1 key (the scripts never emit it - POOL_VERSION is pinned to 2.0.0).
        string memory oldName = string.concat(SYMBOL, "_BurnMintTokenPool_1.6.1");
        string memory newName = DeploymentRecorder._poolName(SYMBOL, "BurnMint"); // ..._2.0.0

        harness.recordDeterministic(sel, "tokenPool", oldName, POOL_V161);

        // A DIFFERENT deployments name (different version key) → guard must NOT revert (no force needed).
        harness.guardForced(sel, newName, false);
        harness.recordDeterministic(sel, "tokenPool", newName, POOL_V200);

        assertEq(harness.readDeployment(sel, oldName), POOL_V161, "1.6.1-keyed entry still resolvable");
        assertEq(harness.readDeployment(sel, newName), POOL_V200, "2.0.0-keyed entry resolvable");
        assertEq(harness.read(sel, "tokenPool"), POOL_V200, "active.tokenPool is the newest write");
        ProjectScratch.clean(SEL_TWOVER);
    }

    // (3) Same-name redeploy is guarded; forcing drops the entry and re-records; siblings survive.
    function test_SameNameRedeploy_Guarded_ForceDropsAndReRecords() public {
        string memory sel = SEL_REDEPLOY;
        string memory name = DeploymentRecorder._poolName(SYMBOL, "BurnMint");
        string memory sibling = DeploymentRecorder._lockBoxName(SYMBOL);

        harness.recordDeterministic(sel, "tokenPool", name, POOL_BURNMINT);
        harness.recordDeterministic(sel, "lockBox", sibling, POOL_LOCKRELEASE);

        // Un-forced redeploy of the SAME name refuses, naming the existing address + the override.
        vm.expectRevert(bytes(_alreadyDeployed(sel, name, POOL_BURNMINT)));
        harness.guardForced(sel, name, false);

        // Forcing drops the entry (and its active pointer), then the redeploy re-records under the name.
        harness.guardForced(sel, name, true);
        assertEq(harness.readDeployment(sel, name), address(0), "stale deployment dropped");
        assertEq(harness.read(sel, "tokenPool"), address(0), "active pointer to dropped addr cleared");
        harness.recordDeterministic(sel, "tokenPool", name, POOL_V200);

        assertEq(harness.readDeployment(sel, name), POOL_V200, "replacement recorded under same name");
        assertEq(harness.readDeployment(sel, sibling), POOL_LOCKRELEASE, "sibling deployment survived");
        assertEq(harness.read(sel, "lockBox"), POOL_LOCKRELEASE, "sibling active pointer survived");
        ProjectScratch.clean(SEL_REDEPLOY);
    }

    // (4) Hooks replacement: new hooks for the same pool are guarded; FORCE_REDEPLOY replaces; the old
    //     address is still in the append-only ledger under history/ (the project store itself is
    //     gitignored, so NOT in git history) - the registry drops it, per the guard's force path.
    function test_HooksReplacement_GuardedThenForced() public {
        string memory sel = SEL_HOOKS;
        string memory name = DeploymentRecorder._hooksName(SYMBOL, "BurnMint");

        harness.recordDeterministic(sel, "poolHooks", name, HOOKS_A);
        assertEq(harness.read(sel, "poolHooks"), HOOKS_A, "initial hooks active");

        // Same name → guarded.
        vm.expectRevert(bytes(_alreadyDeployed(sel, name, HOOKS_A)));
        harness.guardForced(sel, name, false);

        // Forced replacement.
        harness.guardForced(sel, name, true);
        harness.recordDeterministic(sel, "poolHooks", name, HOOKS_B);
        assertEq(harness.readDeployment(sel, name), HOOKS_B, "hooks replaced in registry");
        assertEq(harness.read(sel, "poolHooks"), HOOKS_B, "active.poolHooks is the replacement");
        ProjectScratch.clean(SEL_HOOKS);
    }

    // (5) One call writes BOTH stores: a single deterministic record upserts the named deployment AND
    //     the active role pointer in one write, so the two can never drift (the anti-duplication
    //     invariant).
    function test_OneCallWritesBothStores() public {
        string memory sel = SEL_ONECALL;
        string memory name = DeploymentRecorder._poolName(SYMBOL, "BurnMint");

        harness.recordDeterministic(sel, "tokenPool", name, POOL_BURNMINT);

        assertEq(harness.readDeployment(sel, name), POOL_BURNMINT, "deployments entry written");
        assertEq(harness.read(sel, "tokenPool"), POOL_BURNMINT, "active pointer written by the same call");
        ProjectScratch.clean(SEL_ONECALL);
    }

    // (6) Context-awareness preserved: under `forge test` (TestGroup) the context-aware wrappers are
    //     no-ops - neither the guard nor the record touches the durable store. This is exactly why
    //     BaseForkTest can rerun the real deploy scripts as fixtures without mutating a real registry.
    function test_ContextAware_NoRegistryMutationUnderForgeTest() public {
        assertTrue(vm.isContext(VmSafe.ForgeContext.TestGroup), "precondition: running under forge test");
        string memory sel = SEL_CTXA;
        string memory name = DeploymentRecorder._poolName(SYMBOL, "BurnMint");

        // Even with an entry that WOULD trip the deterministic guard, the context-aware guard no-ops.
        harness.setDeployment(sel, name, POOL_BURNMINT);
        harness.guard(sel, name); // must not revert under forge test

        // The context-aware record no-ops: it must not create/mutate a fresh chain's project file.
        string memory fresh = SEL_CTXB;
        assertFalse(vm.exists(ProjectScratch.projectPath(fresh)), "precondition: no project file");
        harness.record(fresh, "tokenPool", name, POOL_V200);
        assertFalse(
            vm.exists(ProjectScratch.projectPath(fresh)), "context-aware record must not write under forge test"
        );
        ProjectScratch.clean(SEL_CTXA);
        ProjectScratch.clean(SEL_CTXB);
    }

    // The env wrapper honors FORCE_REDEPLOY=true (the exact path the deploy scripts call).
    function test_EnvWrapperHonorsForceRedeploy() public {
        string memory sel = SEL_ENVFORCE;
        string memory name = DeploymentRecorder._poolName(SYMBOL, "BurnMint");
        harness.recordDeterministic(sel, "tokenPool", name, POOL_BURNMINT);
        vm.setEnv("FORCE_REDEPLOY", "true");
        harness.guardEnv(sel, name); // must not revert
        harness.recordDeterministic(sel, "tokenPool", name, POOL_V200);
        assertEq(harness.readDeployment(sel, name), POOL_V200, "replacement registered");
        vm.setEnv("FORCE_REDEPLOY", "false");
        ProjectScratch.clean(SEL_ENVFORCE);
    }

    // The committed example project file parses with the schema-3 reader (schema smoke).
    function test_ExampleProjectParses() public view {
        string memory json = vm.readFile("project/ethereum-testnet-sepolia.example.json");
        assertEq(vm.parseJsonUint(json, ".schema"), ProjectStore.SCHEMA, "example schema is 3");
        assertEq(
            vm.parseJsonAddress(json, ".addresses.active.token"),
            address(0x1111111111111111111111111111111111111111),
            "example active.token entry"
        );
        assertEq(
            vm.parseJsonAddress(json, ".addresses.active.tokenPool"),
            address(0x2222222222222222222222222222222222222222),
            "example active.tokenPool entry"
        );
        assertEq(
            vm.parseJsonAddress(json, ".addresses.deployments[\"BnM-T_BurnMintTokenPool_2.0.0\"]"),
            address(0x2222222222222222222222222222222222222222),
            "example versioned deployments entry"
        );
    }

    function _alreadyDeployed(string memory sel, string memory name, address addr)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "RegistryWriter: '",
            name,
            "' is already deployed at ",
            vm.toString(addr),
            " (",
            ProjectStore._path(sel),
            "). Refusing to redeploy - set FORCE_REDEPLOY=true to deploy a replacement."
        );
    }

    /// A `--broadcast` writes the store during forge's SIMULATION pass, so a transaction that then
    /// fails leaves the address recorded with nothing behind it. The plain refusal sent the operator
    /// looking for that contract; this one reports what the chain said and how to clear it.
    function test_RecordedButNoCodeOnChain_RefusesWithTheAbsenceNamed() public {
        string memory sel = SEL_PHANTOM;
        GuardHarness h = new GuardHarness();
        h.setDeployment(sel, "BnM-T_Token", PHANTOM);

        vm.expectRevert(bytes(_recordedNoCode(sel, "BnM-T_Token", PHANTOM)));
        h.guardWithChainEvidence(sel, "BnM-T_Token", false, false);
        ProjectScratch.clean(sel);
    }

    /// The absence branch must not swallow the ordinary case: when the chain confirms code, the original
    /// message stands, because "already deployed" is then true.
    function test_RecordedWithCode_KeepsThePlainRefusal() public {
        string memory sel = SEL_REAL;
        GuardHarness h = new GuardHarness();
        h.setDeployment(sel, "BnM-T_Token", PHANTOM);

        vm.expectRevert(bytes(_alreadyDeployed(sel, "BnM-T_Token", PHANTOM)));
        h.guardWithChainEvidence(sel, "BnM-T_Token", false, true);
        ProjectScratch.clean(sel);
    }

    /// `FORCE_REDEPLOY=true` is the one command both messages name, so it must clear a phantom entry too:
    /// the `deployments` key and any `active` pointer that resolved to it.
    function test_Phantom_ForceDropsTheStaleEntry() public {
        string memory sel = SEL_PHANTOMFORCE;
        GuardHarness h = new GuardHarness();
        h.recordDeterministic(sel, "token", "BnM-T_Token", PHANTOM);
        assertEq(h.readDeployment(sel, "BnM-T_Token"), PHANTOM, "seeded");
        assertEq(h.read(sel, "token"), PHANTOM, "active pointer seeded");

        h.guardWithChainEvidence(sel, "BnM-T_Token", true, false);

        assertEq(h.readDeployment(sel, "BnM-T_Token"), address(0), "stale entry dropped");
        assertEq(h.read(sel, "token"), address(0), "active pointer that resolved to it dropped too");
        ProjectScratch.clean(sel);
    }

    /// No entry under this name is a first-time flow whatever the chain says - never a revert.
    function test_NoEntry_IsANoOpRegardlessOfChainEvidence() public {
        string memory sel = SEL_FIRSTRUN;
        GuardHarness h = new GuardHarness();
        h.guardWithChainEvidence(sel, "BnM-T_Token", false, false);
        h.guardWithChainEvidence(sel, "BnM-T_Token", false, true);
        assertEq(h.readDeployment(sel, "BnM-T_Token"), address(0), "still nothing recorded");
        ProjectScratch.clean(sel);
    }

    /// @dev The absence message, assembled the way the library assembles it: reword one and this suite
    /// fails until both match again.
    function _recordedNoCode(string memory sel, string memory name, address addr) private view returns (string memory) {
        return string.concat(
            "RegistryWriter: '",
            name,
            "' is recorded at ",
            vm.toString(addr),
            " (",
            ProjectStore._path(sel),
            "), but this run reads no code there on chain ",
            vm.toString(block.chainid),
            ". Three causes read alike here: the broadcast never landed (the store is written from",
            " the simulation, before forge sends), it is still pending, or this run is not reading the",
            " chain that holds it (stale block, wrong or missing RPC). Verify the address before",
            " acting: if it is genuinely absent, FORCE_REDEPLOY=true drops the entry and deploys; if",
            " it exists or is still mining, fix the RPC or wait - forcing leaves two contracts."
        );
    }

    /// The chain read lives in the wrapper, not the core, so the tests above cannot see it: a mutation
    /// making the wrapper pass `true` unconditionally left every one of them green. `vm.etch` supplies
    /// the code, so the branch flips with no fork and no env var.
    function test_GuardAgainstChain_ReadsCodePresence() public {
        string memory sel = SEL_WIRING;
        GuardHarness h = new GuardHarness();
        h.setDeployment(sel, "BnM-T_Token", PHANTOM);

        vm.expectRevert(bytes(_recordedNoCode(sel, "BnM-T_Token", PHANTOM)));
        h.guardAgainstChain(sel, "BnM-T_Token", false);

        vm.etch(PHANTOM, hex"600160005260206000f3");
        vm.expectRevert(bytes(_alreadyDeployed(sel, "BnM-T_Token", PHANTOM)));
        h.guardAgainstChain(sel, "BnM-T_Token", false);
        ProjectScratch.clean(sel);
    }
}
