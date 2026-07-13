// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @title RegistryResolutionTest
/// @notice Deployed-address resolution precedence in `HelperConfig`:
///         inline alias env (`TOKEN_POOL`) > chain-scoped env (`{CHAIN}_TOKEN_POOL`)
///         > address registry (`addresses/<chainId>.json`) > `address(0)`.
/// @dev ONE test function: `vm.setEnv` is process-wide and forge runs tests in parallel, so the
///      env escalation must be strictly ordered inside a single function (env vars are only ever
///      escalated, never unset — the one-way discipline the existing fixtures use). All assertions
///      use the `*_TOKEN_POOL` family on chains no other suite touches: the fork fixtures
///      (`BaseForkTest`) already set the `TOKEN` alias concurrently, so the `TOKEN` ladder cannot
///      be asserted race-free here; `TOKEN` and `TOKEN_POOL` share the exact same resolution code
///      in `HelperConfig._initializeDeployedContracts`, so the ladder proven for `TOKEN_POOL`
///      holds for `TOKEN`.
contract RegistryResolutionTest is Test {
    uint256 internal constant INK_SEPOLIA_CHAIN_ID = 763373;
    uint256 internal constant MANTLE_SEPOLIA_CHAIN_ID = 5003;
    uint256 internal constant PLUME_TESTNET_CHAIN_ID = 98867;

    address internal constant REGISTRY_POOL = address(uint160(0xA1));
    address internal constant CHAIN_ENV_POOL = address(uint160(0xB2));
    address internal constant INLINE_POOL = address(uint160(0xC3));
    address internal constant BACKCOMPAT_POOL = address(uint160(0xD4));

    function _registryPath(uint256 chainId) internal pure returns (string memory) {
        return string.concat("addresses/", vm.toString(chainId), ".json");
    }

    /// @dev Revert-safe cleanup: delete this suite's scratch registry files BEFORE the test runs, never
    /// relying on end-of-test deletion. `addresses/*.json` is gitignored, so a file left behind by a
    /// mid-test revert survives invisibly (`git status` stays clean) and bricks every later `forge test`
    /// (the rung-4 preconditions assert the file is absent). Cleaning up front makes the suite idempotent.
    function setUp() public {
        if (vm.exists(_registryPath(INK_SEPOLIA_CHAIN_ID))) vm.removeFile(_registryPath(INK_SEPOLIA_CHAIN_ID));
        if (vm.exists(_registryPath(MANTLE_SEPOLIA_CHAIN_ID))) vm.removeFile(_registryPath(MANTLE_SEPOLIA_CHAIN_ID));
        if (vm.exists(_registryPath(PLUME_TESTNET_CHAIN_ID))) vm.removeFile(_registryPath(PLUME_TESTNET_CHAIN_ID));
    }

    function test_ResolutionPrecedence_InlineOverChainEnvOverRegistryOverZero() public {
        // Preconditions: the ladder is only observable when the relevant vars start unset
        // (skip instead of failing when the caller's shell already exports them).
        if (
            vm.envOr("TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("INK_SEPOLIA_TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("MANTLE_SEPOLIA_TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("PLUME_TESTNET_TOKEN_POOL", address(0)) != address(0)
        ) {
            vm.skip(true);
        }

        // Rung 4 — nothing anywhere: resolution stays address(0) (unchanged pre-registry behavior).
        assertFalse(vm.exists(_registryPath(PLUME_TESTNET_CHAIN_ID)), "precondition: no plume registry file");
        assertEq(
            new HelperConfig().getDeployedTokenPool(PLUME_TESTNET_CHAIN_ID),
            address(0),
            "absent everywhere must resolve to address(0)"
        );

        // Rung 3 — registry only: the deploy-flow-written file resolves with ZERO env vars.
        RegistryWriter.set(INK_SEPOLIA_CHAIN_ID, "tokenPool", REGISTRY_POOL);
        assertEq(
            new HelperConfig().getDeployedTokenPool(INK_SEPOLIA_CHAIN_ID),
            REGISTRY_POOL,
            "registry entry must resolve when no env var is set"
        );

        // Back-compat — the pre-registry env-var flow keeps working with NO registry file present.
        assertFalse(vm.exists(_registryPath(MANTLE_SEPOLIA_CHAIN_ID)), "precondition: no mantle registry file");
        vm.setEnv("MANTLE_SEPOLIA_TOKEN_POOL", vm.toString(BACKCOMPAT_POOL));
        assertEq(
            new HelperConfig().getDeployedTokenPool(MANTLE_SEPOLIA_CHAIN_ID),
            BACKCOMPAT_POOL,
            "old env-var flow must keep working without any registry file"
        );

        // Rung 2 — chain-scoped env var beats the registry.
        vm.setEnv("INK_SEPOLIA_TOKEN_POOL", vm.toString(CHAIN_ENV_POOL));
        assertEq(
            new HelperConfig().getDeployedTokenPool(INK_SEPOLIA_CHAIN_ID),
            CHAIN_ENV_POOL,
            "chain-scoped env var must beat the registry"
        );

        // Rung 1 — inline alias beats both.
        vm.setEnv("TOKEN_POOL", vm.toString(INLINE_POOL));
        assertEq(
            new HelperConfig().getDeployedTokenPool(INK_SEPOLIA_CHAIN_ID),
            INLINE_POOL,
            "inline TOKEN_POOL alias must beat the chain-scoped env var and the registry"
        );

        vm.removeFile(_registryPath(INK_SEPOLIA_CHAIN_ID));
    }
}

/// @title RegistryResolutionExtrasTest
/// @notice The same deployed-address ladder, now proven for the two artifacts wired in this PR:
///         `lockBox` and `poolHooks` (previously written to the registry but never read back). The
///         `HelperConfig` getters resolve: inline alias > `{CHAIN}_` env > registry `active.<role>`
///         > `address(0)`.
/// @dev Uses the 0g testnet chain (16602) — a configured chain NO other suite touches — so its
///      registry file and chain-scoped env vars cannot race the ladder above (which uses ink/mantle/
///      plume) or the Sepolia fork fixtures. Rungs 2-4 are asserted directly here. Rung 1 (the bare
///      inline `LOCK_BOX` / `POOL_HOOKS` alias) is deliberately NOT set process-wide: the deploy/ops
///      fork fixtures consume the lockbox/hooks addresses via the CHAIN-SCOPED vars
///      (`LockboxOps` sets `ETHEREUM_SEPOLIA_LOCK_BOX`, not the bare `LOCK_BOX`), and no suite sets the
///      bare `LOCK_BOX`/`POOL_HOOKS` alias, so rungs 2-4 here are race-free. The inline rung is the
///      identical `vm.envOr("LOCK_BOX"/"POOL_HOOKS", getter)` first argument already proven race-free
///      for `TOKEN_POOL` above — the same code, so the same ladder holds.
contract RegistryResolutionExtrasTest is Test {
    uint256 internal constant ZERO_G_TESTNET_CHAIN_ID = 16602;
    string internal constant CHAIN_LOCK_BOX_ENV = "0G_GALILEO_TESTNET_LOCK_BOX";
    string internal constant CHAIN_POOL_HOOKS_ENV = "0G_GALILEO_TESTNET_POOL_HOOKS";

    address internal constant REG_LOCK_BOX = address(uint160(0xB0));
    address internal constant REG_POOL_HOOKS = address(uint160(0xB1));
    address internal constant CHAIN_LOCK_BOX = address(uint160(0xC0));
    address internal constant CHAIN_POOL_HOOKS = address(uint160(0xC1));

    function _registryPath(uint256 chainId) internal pure returns (string memory) {
        return string.concat("addresses/", vm.toString(chainId), ".json");
    }

    /// @dev Revert-safe cleanup (see the sibling `RegistryResolutionTest.setUp`): delete the scratch
    /// `addresses/16602.json` BEFORE the precondition, so a mid-test revert can never leave a gitignored
    /// file that deterministically bricks the next `forge test` at "precondition: no 0g registry file".
    function setUp() public {
        if (vm.exists(_registryPath(ZERO_G_TESTNET_CHAIN_ID))) vm.removeFile(_registryPath(ZERO_G_TESTNET_CHAIN_ID));
    }

    function test_LockBoxAndPoolHooks_ResolutionLadder() public {
        // Preconditions: observable only when the relevant vars start unset (skip, don't fail).
        if (
            vm.envOr("LOCK_BOX", address(0)) != address(0) || vm.envOr("POOL_HOOKS", address(0)) != address(0)
                || vm.envOr(CHAIN_LOCK_BOX_ENV, address(0)) != address(0)
                || vm.envOr(CHAIN_POOL_HOOKS_ENV, address(0)) != address(0)
        ) {
            vm.skip(true);
        }

        // Rung 4 — nothing anywhere: both resolve to address(0).
        assertFalse(vm.exists(_registryPath(ZERO_G_TESTNET_CHAIN_ID)), "precondition: no 0g registry file");
        assertEq(new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID), address(0), "lockBox absent -> 0");
        assertEq(new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID), address(0), "poolHooks absent -> 0");

        // Rung 3 — registry only (the deploy-flow-written active pointers) resolves with ZERO env vars.
        // This is the exact zero-export promise: after a lockbox/hooks deploy, later scripts resolve them.
        RegistryWriter.setActive(ZERO_G_TESTNET_CHAIN_ID, "lockBox", REG_LOCK_BOX);
        RegistryWriter.setActive(ZERO_G_TESTNET_CHAIN_ID, "poolHooks", REG_POOL_HOOKS);
        assertEq(
            new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID),
            REG_LOCK_BOX,
            "registry active.lockBox resolves with no env var"
        );
        assertEq(
            new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID),
            REG_POOL_HOOKS,
            "registry active.poolHooks resolves with no env var"
        );

        // Rung 2 — chain-scoped env var beats the registry. These `{CHAIN}_` vars are 0g-specific, so
        // they cannot leak into the Sepolia fork fixtures.
        vm.setEnv(CHAIN_LOCK_BOX_ENV, vm.toString(CHAIN_LOCK_BOX));
        vm.setEnv(CHAIN_POOL_HOOKS_ENV, vm.toString(CHAIN_POOL_HOOKS));
        assertEq(
            new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID),
            CHAIN_LOCK_BOX,
            "chain-scoped env beats the registry (lockBox)"
        );
        assertEq(
            new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID),
            CHAIN_POOL_HOOKS,
            "chain-scoped env beats the registry (poolHooks)"
        );

        vm.removeFile(_registryPath(ZERO_G_TESTNET_CHAIN_ID));
    }
}
