// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice The `make doctor` registry rung reconciles the registry's pool (`active.tokenPool`) against the
/// pool actually wired in the on-chain TokenAdminRegistry. It must PASS on a match, WARN (never FAIL) on a
/// divergence (legitimate when the wired pool was changed out-of-band), and WARN when the token has no
/// TAR entry. This asserts the WARN-not-FAIL contract directly via `VerifyChain.reconcilePoolWithTarForTest`.
contract VerifyChainTarReconcileForkTest is BaseForkTest {
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
    }

    function _register() internal {
        vm.startPrank(deployer);
        registryModule.registerAdminViaGetCCIPAdmin(token);
        registry.acceptAdminRole(token);
        vm.stopPrank();
    }

    // PASS: the registry pool IS the pool wired in the TAR -> no WARN, no FAIL.
    function test_Reconcile_Pass_WhenRegistryPoolIsWired() public {
        _register();
        vm.prank(deployer);
        registry.setPool(token, pool);

        (uint256 fails, uint256 warns) = new VerifyChain().reconcilePoolWithTarForTest(address(registry), token, pool);
        assertEq(fails, 0, "match must never FAIL");
        assertEq(warns, 0, "match must not WARN");
    }

    // WARN: the registry pool differs from the wired pool (out-of-band change) -> WARN, still 0 FAIL.
    function test_Reconcile_Warn_WhenRegistryPoolDivergesFromWired() public {
        _register();
        vm.prank(deployer);
        registry.setPool(token, pool); // TAR is wired to `pool`

        // Simulate `active.tokenPool` pointing at a different pool than the one the TAR routes through.
        address newerPool = address(0xBEEF);
        (uint256 fails, uint256 warns) =
            new VerifyChain().reconcilePoolWithTarForTest(address(registry), token, newerPool);
        assertEq(fails, 0, "divergence must never FAIL (legitimate out-of-band change)");
        assertEq(warns, 1, "divergence must emit exactly one WARN");
    }

    // WARN: the token has no pool registered in the TAR -> WARN, still 0 FAIL.
    function test_Reconcile_Warn_WhenTokenHasNoTarEntry() public {
        // Token registered (admin accepted) but setPool never called: wired pool is address(0).
        _register();
        (uint256 fails, uint256 warns) = new VerifyChain().reconcilePoolWithTarForTest(address(registry), token, pool);
        assertEq(fails, 0, "no-entry must never FAIL");
        assertEq(warns, 1, "no-entry must emit exactly one WARN");
    }
}
