// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeploymentUtils} from "../../script/utils/DeploymentUtils.s.sol";
import {DeploymentRecorder} from "../../script/utils/DeploymentRecorder.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @dev A token exposing `symbol()` so the pool/lock-box/hooks ledger path (which resolves the file's
/// symbol prefix and the store's key via `DeploymentUtils.getSymbol`'s on-chain `symbol()` call) has a
/// real contract to read. Parameterized so the multi-deploy test can mint distinct symbols.
contract SymToken {
    string public symbol;

    constructor(string memory s) {
        symbol = s;
    }
}

/// @title ArtifactRecordCompletenessTest — EVERY deployed artifact type lands in BOTH stores
/// @notice Closes the per-artifact completeness gap: the existing `HistoryLedger` suite pins the token +
/// burn-mint-pool `history/` bodies, and the `Registry*` suites pin the `project/` store, but NOTHING
/// asserted the two halves TOGETHER for all five artifact roles, nor the LockRelease / lockBox / poolHooks
/// history bodies, nor history append-only ACROSS DIFFERENT artifacts. This suite drives the same two
/// writes `DeploymentRecorder.record*` performs — `DeploymentUtils.save*` (the `history/` half, always
/// writes) + `RegistryWriter.recordDeterministic(sel, role, DeploymentRecorder.<name>(...), addr)` (the
/// `project/` store half; the deterministic core is used because `RegistryWriter.record` no-ops under
/// `forge test` context by design) — using the recorder's OWN key helpers, so a drift between the store key
/// and the history filename symbol would fail here.
///
/// For EACH of token / burn-mint pool / lock-release pool (incl. the `LOCK_BOX` body key) / lockBox /
/// poolHooks it asserts BOTH:
///   (a) `project/<sel>.json` `addresses.active.<role>` AND `addresses.deployments[<name>]` hold the address;
///   (b) a `history/<category>/<sel>/<ts>-….json` file exists with the frozen body format.
/// Clock is INJECTED (`vm.warp`) so filenames are deterministic; scratch basenames are unique per test and
/// cleaned in `setUp()`.
contract ArtifactRecordCompletenessTest is Test {
    string internal constant SEL_TOKEN = "zz-scratch-arc-token";
    string internal constant SEL_BM = "zz-scratch-arc-burnmint";
    string internal constant SEL_LR = "zz-scratch-arc-lockrelease";
    string internal constant SEL_LB = "zz-scratch-arc-lockbox";
    string internal constant SEL_HOOKS = "zz-scratch-arc-hooks";
    string internal constant SEL_MULTI = "zz-scratch-arc-multi";

    string internal constant CNI = "ETHEREUM_SEPOLIA";
    uint256 internal constant T1 = 1_700_000_000;
    uint256 internal constant T2 = 1_700_000_050;
    uint256 internal constant T3 = 1_700_000_100;

    function setUp() public {
        string[6] memory sels = [SEL_TOKEN, SEL_BM, SEL_LR, SEL_LB, SEL_HOOKS, SEL_MULTI];
        for (uint256 i = 0; i < sels.length; i++) {
            ProjectScratch.clean(sels[i]); // project/ + config/chains scratch
            ProjectScratch.cleanHistory(sels[i]); // history/<cat>/<sel> dirs
        }
    }

    function _histDir(string memory cat, string memory sel) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/history/", cat, "/", sel, "/");
    }

    // ─────────────────────────────────────────── (1) token: store + history

    function test_Token_StoreAndHistory() public {
        vm.warp(T1);
        address token = address(new SymToken("BnM-T"));
        string memory name = DeploymentRecorder.tokenName("BnM-T");

        // history half (what DeploymentRecorder.recordToken writes)
        DeploymentUtils.saveTokenDeployment(vm, SEL_TOKEN, CNI, "BnM-T", token);
        string memory file = string.concat(_histDir("tokens", SEL_TOKEN), vm.toString(T1), "-BnM-T-Token.json");
        assertTrue(vm.exists(file), "token history file written");
        string memory body = vm.readFile(file);
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN")), token, "token history body key");

        // store half (same key the recorder composes)
        RegistryWriter.recordDeterministic(SEL_TOKEN, "token", name, token);
        assertEq(RegistryWriter.read(SEL_TOKEN, "token"), token, "active.token");
        assertEq(RegistryWriter.readDeployment(SEL_TOKEN, name), token, "deployments[token]");
    }

    // ─────────────────────────────────────────── (2) burn-mint pool: store + history

    function test_BurnMintPool_StoreAndHistory() public {
        vm.warp(T1);
        address token = address(new SymToken("BnM-T"));
        address pool = address(0xBEEf000000000000000000000000000000000001);
        string memory name = DeploymentRecorder.poolName("BnM-T", "BurnMint");

        DeploymentUtils.saveTokenPoolDeployment(vm, SEL_BM, CNI, pool, token, "BurnMint");
        string memory file =
            string.concat(_histDir("token-pools", SEL_BM), vm.toString(T1), "-BnM-T-BurnMintTokenPool.json");
        assertTrue(vm.exists(file), "burnmint pool history file written");
        string memory body = vm.readFile(file);
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN_POOL")), pool, "pool key");
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN")), token, "token key");
        // Frozen burn-mint body: NO LOCK_BOX key (that belongs to the lock-release body only).
        assertFalse(vm.keyExistsJson(body, ".LOCK_BOX"), "burnmint body must NOT carry a LOCK_BOX key");

        RegistryWriter.recordDeterministic(SEL_BM, "tokenPool", name, pool);
        assertEq(RegistryWriter.read(SEL_BM, "tokenPool"), pool, "active.tokenPool");
        assertEq(RegistryWriter.readDeployment(SEL_BM, name), pool, "deployments[burnmint pool]");
        assertEq(name, "BnM-T_BurnMintTokenPool_2.0.0", "versioned pool key composed");
    }

    // ─────────────────────────────────────────── (3) lock-release pool: store + history (incl. LOCK_BOX body)

    function test_LockReleasePool_StoreAndHistory_LockBoxBody() public {
        vm.warp(T1);
        address token = address(new SymToken("LR-T"));
        address pool = address(0xbeeF000000000000000000000000000000000002);
        address lockBox = address(0xB0C5000000000000000000000000000000000003);
        string memory name = DeploymentRecorder.poolName("LR-T", "LockRelease");

        DeploymentUtils.saveLockReleaseTokenPoolDeployment(vm, SEL_LR, CNI, pool, token, lockBox, "LockRelease");
        string memory file =
            string.concat(_histDir("token-pools", SEL_LR), vm.toString(T1), "-LR-T-LockReleaseTokenPool.json");
        assertTrue(vm.exists(file), "lock-release pool history file written");
        string memory body = vm.readFile(file);
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN_POOL")), pool, "pool key");
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN")), token, "token key");
        // The lock-release body's distinguishing key: the associated lock box.
        assertEq(vm.parseJsonAddress(body, ".LOCK_BOX"), lockBox, "LOCK_BOX key in lock-release body");

        RegistryWriter.recordDeterministic(SEL_LR, "tokenPool", name, pool);
        assertEq(RegistryWriter.read(SEL_LR, "tokenPool"), pool, "active.tokenPool");
        assertEq(RegistryWriter.readDeployment(SEL_LR, name), pool, "deployments[lockrelease pool]");
    }

    // ─────────────────────────────────────────── (4) lockBox: store + history

    function test_LockBox_StoreAndHistory() public {
        vm.warp(T1);
        address token = address(new SymToken("LR-T"));
        address lockBox = address(0xb0C5000000000000000000000000000000000004);
        string memory name = DeploymentRecorder.lockBoxName("LR-T");

        DeploymentUtils.saveLockBoxDeployment(vm, SEL_LB, CNI, lockBox, token);
        string memory file = string.concat(_histDir("lock-boxes", SEL_LB), vm.toString(T1), "-LR-T-LockBox.json");
        assertTrue(vm.exists(file), "lockbox history file written");
        string memory body = vm.readFile(file);
        assertEq(vm.parseJsonAddress(body, ".LOCK_BOX"), lockBox, "LOCK_BOX key");
        assertEq(vm.parseJsonAddress(body, string.concat(".", CNI, "_TOKEN")), token, "token key");

        RegistryWriter.recordDeterministic(SEL_LB, "lockBox", name, lockBox);
        assertEq(RegistryWriter.read(SEL_LB, "lockBox"), lockBox, "active.lockBox");
        assertEq(RegistryWriter.readDeployment(SEL_LB, name), lockBox, "deployments[lockBox]");
        assertEq(name, "LR-T_LockBox", "lockBox key composed");
    }

    // ─────────────────────────────────────────── (5) poolHooks: store + history

    function test_PoolHooks_StoreAndHistory() public {
        vm.warp(T1);
        address token = address(new SymToken("ACE-T"));
        address hooks = address(0x40c5000000000000000000000000000000000005);
        string memory name = DeploymentRecorder.hooksName("ACE-T", "BurnMint");

        DeploymentUtils.savePoolHooksDeployment(vm, SEL_HOOKS, "ACE-T", "BurnMint", hooks);
        string memory file = string.concat(
            _histDir("advanced-pool-hooks", SEL_HOOKS), vm.toString(T1), "-ACE-T-BurnMintAdvancedPoolHooks.json"
        );
        assertTrue(vm.exists(file), "poolHooks history file written");
        string memory body = vm.readFile(file);
        assertEq(vm.parseJsonAddress(body, ".POOL_HOOKS"), hooks, "POOL_HOOKS key");

        RegistryWriter.recordDeterministic(SEL_HOOKS, "poolHooks", name, hooks);
        assertEq(RegistryWriter.read(SEL_HOOKS, "poolHooks"), hooks, "active.poolHooks");
        assertEq(RegistryWriter.readDeployment(SEL_HOOKS, name), hooks, "deployments[poolHooks]");
        assertEq(name, "ACE-T_BurnMint_PoolHooks", "hooks key composed");
    }

    // ─────────────────────────────────────────── multi-deploy: several DISTINCT pools on ONE chain

    /// @dev Deploy-record two DISTINCT burn-mint pools (different symbols) then a lock-release pool on ONE
    /// scratch chain, each at a later injected clock. Assert: every prior history file survives (append-only
    /// across DIFFERENT artifacts), the `deployments{}` map holds ALL THREE keyed distinctly, and
    /// `active.tokenPool` points at the NEWEST write. This also REGRESSION-GUARDS the serialization-handle
    /// bleed: the burn-mint bodies must never carry a `LOCK_BOX` key even though a lock-release save shares
    /// the process (the fix keys each `vm.serializeAddress` journal by the artifact address).
    function test_MultiPool_HistoryAppendsAcrossArtifacts_StoreCoherent() public {
        address tokA = address(new SymToken("AAA"));
        address tokB = address(new SymToken("BBB"));
        address tokC = address(new SymToken("CCC"));
        address poolA = address(0xA000000000000000000000000000000000000001);
        address poolB = address(0xb000000000000000000000000000000000000002);
        address poolC = address(0xC000000000000000000000000000000000000003);
        address lockBoxC = address(0xCb00000000000000000000000000000000000004);

        // 1) burn-mint AAA
        vm.warp(T1);
        DeploymentUtils.saveTokenPoolDeployment(vm, SEL_MULTI, CNI, poolA, tokA, "BurnMint");
        RegistryWriter.recordDeterministic(
            SEL_MULTI, "tokenPool", DeploymentRecorder.poolName("AAA", "BurnMint"), poolA
        );

        // 2) lock-release CCC (SANDWICHED before the second burn-mint to exercise handle isolation)
        vm.warp(T2);
        DeploymentUtils.saveLockReleaseTokenPoolDeployment(vm, SEL_MULTI, CNI, poolC, tokC, lockBoxC, "LockRelease");
        RegistryWriter.recordDeterministic(
            SEL_MULTI, "tokenPool", DeploymentRecorder.poolName("CCC", "LockRelease"), poolC
        );

        // 3) burn-mint BBB (LAST write -> becomes active.tokenPool)
        vm.warp(T3);
        DeploymentUtils.saveTokenPoolDeployment(vm, SEL_MULTI, CNI, poolB, tokB, "BurnMint");
        RegistryWriter.recordDeterministic(
            SEL_MULTI, "tokenPool", DeploymentRecorder.poolName("BBB", "BurnMint"), poolB
        );

        // history: all THREE files present (append-only across different artifacts).
        string memory dir = _histDir("token-pools", SEL_MULTI);
        assertTrue(vm.exists(string.concat(dir, vm.toString(T1), "-AAA-BurnMintTokenPool.json")), "AAA hist");
        assertTrue(vm.exists(string.concat(dir, vm.toString(T2), "-CCC-LockReleaseTokenPool.json")), "CCC hist");
        assertTrue(vm.exists(string.concat(dir, vm.toString(T3), "-BBB-BurnMintTokenPool.json")), "BBB hist");
        assertEq(vm.readDir(string.concat(vm.projectRoot(), "/history/token-pools/", SEL_MULTI)).length, 3, "3 files");

        // REGRESSION: the burn-mint bodies carry NO LOCK_BOX even though a lock-release save shares the process.
        string memory bmA = vm.readFile(string.concat(dir, vm.toString(T1), "-AAA-BurnMintTokenPool.json"));
        string memory bmB = vm.readFile(string.concat(dir, vm.toString(T3), "-BBB-BurnMintTokenPool.json"));
        assertFalse(vm.keyExistsJson(bmA, ".LOCK_BOX"), "AAA burnmint body must have no LOCK_BOX (handle bleed)");
        assertFalse(vm.keyExistsJson(bmB, ".LOCK_BOX"), "BBB burnmint body must have no LOCK_BOX (handle bleed)");
        // The lock-release body DOES carry LOCK_BOX (its correct format).
        string memory lrC = vm.readFile(string.concat(dir, vm.toString(T2), "-CCC-LockReleaseTokenPool.json"));
        assertEq(vm.parseJsonAddress(lrC, ".LOCK_BOX"), lockBoxC, "CCC lock-release body keeps LOCK_BOX");

        // store: all three deployments keyed distinctly, active.tokenPool == newest (BBB burn-mint).
        assertEq(RegistryWriter.readDeployment(SEL_MULTI, "AAA_BurnMintTokenPool_2.0.0"), poolA, "AAA deployment");
        assertEq(RegistryWriter.readDeployment(SEL_MULTI, "CCC_LockReleaseTokenPool_2.0.0"), poolC, "CCC deployment");
        assertEq(RegistryWriter.readDeployment(SEL_MULTI, "BBB_BurnMintTokenPool_2.0.0"), poolB, "BBB deployment");
        assertEq(RegistryWriter.read(SEL_MULTI, "tokenPool"), poolB, "active.tokenPool is the newest write (BBB)");
    }
}
