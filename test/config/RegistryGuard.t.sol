// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {DeploymentRecorder} from "../../script/utils/DeploymentRecorder.s.sol";

/// @dev External wrapper so `vm.expectRevert` can observe the library's revert (internal library
/// calls are inlined into the test frame otherwise), and so the tests drive the deterministic cores
/// directly (the context-aware `guard`/`record` no-op under `forge test`, which is exactly the
/// inertness `BaseForkTest` relies on — see `test_ContextAware_NoRegistryMutationUnderForgeTest`).
contract GuardHarness {
    function guardForced(uint256 chainId, string memory name, bool forced) external {
        RegistryWriter.guardRedeploy(chainId, name, forced);
    }

    function guardEnv(uint256 chainId, string memory name) external {
        RegistryWriter.guardRedeploy(chainId, name);
    }

    function recordDeterministic(uint256 chainId, string memory role, string memory name, address addr) external {
        RegistryWriter.recordDeterministic(chainId, role, name, addr);
    }

    function record(uint256 chainId, string memory role, string memory name, address addr) external {
        RegistryWriter.record(chainId, role, name, addr);
    }

    function guard(uint256 chainId, string memory name) external {
        RegistryWriter.guard(chainId, name);
    }

    function setActive(uint256 chainId, string memory role, address addr) external {
        RegistryWriter.setActive(chainId, role, addr);
    }

    function setDeployment(uint256 chainId, string memory name, address addr) external {
        RegistryWriter.setDeployment(chainId, name, addr);
    }

    function read(uint256 chainId, string memory role) external view returns (address) {
        return RegistryWriter.read(chainId, role);
    }

    function readDeployment(uint256 chainId, string memory name) external view returns (address) {
        return RegistryWriter.readDeployment(chainId, name);
    }
}

/// @notice Registry schema v2 (`active` role pointers + named `deployments`) and its single-writer
/// record + redeploy guard. Each test uses its OWN throwaway `addresses/<fake chainId>.json` (removed
/// at the end): forge runs tests in parallel, and no real chain's registry file is ever touched. The
/// deploy-time keys are composed through `DeploymentRecorder` so the tests key exactly as the scripts do.
contract RegistryGuardTest is Test {
    // A BurnMint and a LockRelease pool for the same token, and two versions of the BurnMint pool.
    string internal constant SYMBOL = "BnM-T";
    address internal constant TOKEN = address(0x1111111111111111111111111111111111111111);
    address internal constant POOL_BURNMINT = address(0x2222222222222222222222222222222222222222);
    address internal constant POOL_LOCKRELEASE = address(0x3333333333333333333333333333333333333333);
    address internal constant POOL_V161 = address(0x4444444444444444444444444444444444444444);
    address internal constant POOL_V200 = address(0x5555555555555555555555555555555555555555);
    address internal constant HOOKS_A = address(0x6666666666666666666666666666666666666666);
    address internal constant HOOKS_B = address(0x7777777777777777777777777777777777777777);

    GuardHarness internal harness;

    function setUp() public {
        harness = new GuardHarness();
    }

    function _path(uint256 chainId) internal pure returns (string memory) {
        return string.concat("addresses/", vm.toString(chainId), ".json");
    }

    function _rm(uint256 chainId) internal {
        if (vm.exists(_path(chainId))) vm.removeFile(_path(chainId));
    }

    // (1) No cross-pool-type collision: a BurnMint and a LockRelease pool for the SAME token on one
    //     chain both record and both resolve; neither clobbers the other's deployments entry.
    function test_CrossPoolType_BothResolvable_NoClobber() public {
        uint256 chainId = 900_000_000_101;
        string memory bmName = DeploymentRecorder.poolName(SYMBOL, "BurnMint");
        string memory lrName = DeploymentRecorder.poolName(SYMBOL, "LockRelease");

        harness.recordDeterministic(chainId, "tokenPool", bmName, POOL_BURNMINT);
        harness.recordDeterministic(chainId, "tokenPool", lrName, POOL_LOCKRELEASE);

        assertEq(harness.readDeployment(chainId, bmName), POOL_BURNMINT, "BurnMint pool resolvable");
        assertEq(harness.readDeployment(chainId, lrName), POOL_LOCKRELEASE, "LockRelease pool resolvable");
        // active.tokenPool mirrors the most-recently-recorded pool.
        assertEq(harness.read(chainId, "tokenPool"), POOL_LOCKRELEASE, "active.tokenPool is newest");
        _rm(chainId);
    }

    // (2) Registry DATA LAYER holds two versioned entries: because the deployments key carries the pool
    //     type + version, two version keys (1.6.1, 2.0.0) coexist without tripping the guard, both
    //     addresses resolve via readDeployment, and active.tokenPool mirrors the newest write. This
    //     proves ONLY the storage layer — it is NOT a migration flow reachable through the deploy
    //     scripts: `DeploymentRecorder.POOL_VERSION` is hardcoded "2.0.0", so the scripts only ever emit
    //     the _2.0.0 key. The 1.6.1 key below is hand-injected to exercise the data structure directly.
    function test_TwoVersionedEntries_CoexistInRegistryDataLayer() public {
        uint256 chainId = 900_000_000_102;
        // Hand-inject a 1.6.1 key (the scripts never emit it — POOL_VERSION is pinned to 2.0.0).
        string memory oldName = string.concat(SYMBOL, "_BurnMintTokenPool_1.6.1");
        string memory newName = DeploymentRecorder.poolName(SYMBOL, "BurnMint"); // ..._2.0.0

        harness.recordDeterministic(chainId, "tokenPool", oldName, POOL_V161);

        // A DIFFERENT deployments name (different version key) → guard must NOT revert (no force needed).
        harness.guardForced(chainId, newName, false);
        harness.recordDeterministic(chainId, "tokenPool", newName, POOL_V200);

        assertEq(harness.readDeployment(chainId, oldName), POOL_V161, "1.6.1-keyed entry still resolvable");
        assertEq(harness.readDeployment(chainId, newName), POOL_V200, "2.0.0-keyed entry resolvable");
        assertEq(harness.read(chainId, "tokenPool"), POOL_V200, "active.tokenPool is the newest write");
        _rm(chainId);
    }

    // (3) Same-name redeploy is guarded; forcing drops the entry and re-records; siblings survive.
    function test_SameNameRedeploy_Guarded_ForceDropsAndReRecords() public {
        uint256 chainId = 900_000_000_103;
        string memory name = DeploymentRecorder.poolName(SYMBOL, "BurnMint");
        string memory sibling = DeploymentRecorder.lockBoxName(SYMBOL);

        harness.recordDeterministic(chainId, "tokenPool", name, POOL_BURNMINT);
        harness.recordDeterministic(chainId, "lockBox", sibling, POOL_LOCKRELEASE);

        // Un-forced redeploy of the SAME name refuses, naming the existing address + the override.
        vm.expectRevert(
            bytes(
                string.concat(
                    "RegistryWriter: '",
                    name,
                    "' is already deployed at ",
                    vm.toString(POOL_BURNMINT),
                    " (",
                    string.concat(vm.projectRoot(), "/", _path(chainId)),
                    "). Refusing to redeploy - set FORCE_REDEPLOY=true to deploy a replacement."
                )
            )
        );
        harness.guardForced(chainId, name, false);

        // Forcing drops the entry (and its active pointer), then the redeploy re-records under the name.
        harness.guardForced(chainId, name, true);
        assertEq(harness.readDeployment(chainId, name), address(0), "stale deployment dropped");
        assertEq(harness.read(chainId, "tokenPool"), address(0), "active pointer to dropped addr cleared");
        harness.recordDeterministic(chainId, "tokenPool", name, POOL_V200);

        assertEq(harness.readDeployment(chainId, name), POOL_V200, "replacement recorded under same name");
        assertEq(harness.readDeployment(chainId, sibling), POOL_LOCKRELEASE, "sibling deployment survived");
        assertEq(harness.read(chainId, "lockBox"), POOL_LOCKRELEASE, "sibling active pointer survived");
        _rm(chainId);
    }

    // (4) Hooks replacement: new hooks for the same pool are guarded; FORCE_REDEPLOY replaces; the old
    //     address is still in the append-only ledger under script/deployments (the registry itself is
    //     gitignored, so NOT in git history) — the registry drops it, per the guard's force path.
    function test_HooksReplacement_GuardedThenForced() public {
        uint256 chainId = 900_000_000_104;
        string memory name = DeploymentRecorder.hooksName(SYMBOL, "BurnMint");

        harness.recordDeterministic(chainId, "poolHooks", name, HOOKS_A);
        assertEq(harness.read(chainId, "poolHooks"), HOOKS_A, "initial hooks active");

        // Same name → guarded.
        vm.expectRevert(bytes(_alreadyDeployed(chainId, name, HOOKS_A)));
        harness.guardForced(chainId, name, false);

        // Forced replacement.
        harness.guardForced(chainId, name, true);
        harness.recordDeterministic(chainId, "poolHooks", name, HOOKS_B);
        assertEq(harness.readDeployment(chainId, name), HOOKS_B, "hooks replaced in registry");
        assertEq(harness.read(chainId, "poolHooks"), HOOKS_B, "active.poolHooks is the replacement");
        _rm(chainId);
    }

    // (5) One call writes BOTH stores: a single deterministic record upserts the named deployment AND
    //     the active role pointer in one write, so the two can never drift (the anti-duplication
    //     invariant Syed asked for). The recorder facade folds this together with the ledger file; the
    //     ledger half is asserted in the fork end-to-end proof (the registry half no-ops under forge
    //     test, mirroring BaseForkTest inertness — see the context-awareness test below).
    function test_OneCallWritesBothStores() public {
        uint256 chainId = 900_000_000_105;
        string memory name = DeploymentRecorder.poolName(SYMBOL, "BurnMint");

        harness.recordDeterministic(chainId, "tokenPool", name, POOL_BURNMINT);

        assertEq(harness.readDeployment(chainId, name), POOL_BURNMINT, "deployments entry written");
        assertEq(harness.read(chainId, "tokenPool"), POOL_BURNMINT, "active pointer written by the same call");
        _rm(chainId);
    }

    // (6) Context-awareness preserved: under `forge test` (TestGroup) the context-aware wrappers are
    //     no-ops — neither the guard nor the record touches the durable store. This is exactly why
    //     BaseForkTest can rerun the real deploy scripts as fixtures without mutating a real registry.
    function test_ContextAware_NoRegistryMutationUnderForgeTest() public {
        assertTrue(vm.isContext(VmSafe.ForgeContext.TestGroup), "precondition: running under forge test");
        uint256 chainId = 900_000_000_106;
        string memory name = DeploymentRecorder.poolName(SYMBOL, "BurnMint");

        // Even with an entry that WOULD trip the deterministic guard, the context-aware guard no-ops.
        harness.setDeployment(chainId, name, POOL_BURNMINT);
        harness.guard(chainId, name); // must not revert under forge test

        // The context-aware record no-ops: it must not create/mutate a fresh chain's registry.
        uint256 freshChain = 900_000_000_107;
        assertFalse(vm.exists(_path(freshChain)), "precondition: no registry file");
        harness.record(freshChain, "tokenPool", name, POOL_V200);
        assertFalse(vm.exists(_path(freshChain)), "context-aware record must not write under forge test");

        _rm(chainId);
    }

    // (7) Legacy fallback: a pre-v2 FLAT `{ "<role>": "0x.." }` registry still resolves via read().
    function test_LegacyFlatRegistryStillResolves() public {
        uint256 chainId = 900_000_000_108;
        vm.writeFile(
            _path(chainId),
            string.concat(
                "{\n    \"token\": \"",
                vm.toString(TOKEN),
                "\",\n    \"tokenPool\": \"",
                vm.toString(POOL_BURNMINT),
                "\"\n}\n"
            )
        );
        assertEq(harness.read(chainId, "token"), TOKEN, "legacy flat token resolves");
        assertEq(harness.read(chainId, "tokenPool"), POOL_BURNMINT, "legacy flat tokenPool resolves");
        assertEq(harness.read(chainId, "lockBox"), address(0), "absent legacy role resolves to 0");
        _rm(chainId);
    }

    // The env wrapper honors FORCE_REDEPLOY=true (the exact path the deploy scripts call).
    function test_EnvWrapperHonorsForceRedeploy() public {
        uint256 chainId = 900_000_000_109;
        string memory name = DeploymentRecorder.poolName(SYMBOL, "BurnMint");
        harness.recordDeterministic(chainId, "tokenPool", name, POOL_BURNMINT);
        vm.setEnv("FORCE_REDEPLOY", "true");
        harness.guardEnv(chainId, name); // must not revert
        harness.recordDeterministic(chainId, "tokenPool", name, POOL_V200);
        assertEq(harness.readDeployment(chainId, name), POOL_V200, "replacement registered");
        vm.setEnv("FORCE_REDEPLOY", "false");
        _rm(chainId);
    }

    // The committed example registry parses with the v2 reader (schema smoke).
    function test_ExampleRegistryParses() public view {
        string memory json = vm.readFile("addresses/11155111.example.json");
        assertEq(
            vm.parseJsonAddress(json, ".active.token"),
            address(0x1111111111111111111111111111111111111111),
            "example active.token entry"
        );
        assertEq(
            vm.parseJsonAddress(json, ".active.tokenPool"),
            address(0x2222222222222222222222222222222222222222),
            "example active.tokenPool entry"
        );
        assertEq(
            vm.parseJsonAddress(json, ".deployments[\"BnM-T_BurnMintTokenPool_2.0.0\"]"),
            address(0x2222222222222222222222222222222222222222),
            "example versioned deployments entry"
        );
    }

    function _alreadyDeployed(uint256 chainId, string memory name, address addr) internal view returns (string memory) {
        return string.concat(
            "RegistryWriter: '",
            name,
            "' is already deployed at ",
            vm.toString(addr),
            " (",
            string.concat(vm.projectRoot(), "/", _path(chainId)),
            "). Refusing to redeploy - set FORCE_REDEPLOY=true to deploy a replacement."
        );
    }
}
