// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SetDynamicConfig} from "../../script/configure/dynamic-config/SetDynamicConfig.s.sol";

/// @dev Exposes the resolution with the env access swapped for an injectable fake (the `_dcEnvOr`
///      seam exists for exactly this: ROUTER/RATE_LIMIT_ADMIN/FEE_ADMIN are process-wide names and
///      suites run in parallel, so tests must never `vm.setEnv` them).
contract DynamicConfigHarness is SetDynamicConfig {
    mapping(bytes32 => address) private fakeEnv;
    mapping(bytes32 => bool) private fakeSet;

    function setFakeEnv(string memory name, address value) external {
        fakeEnv[keccak256(bytes(name))] = value;
        fakeSet[keccak256(bytes(name))] = true;
    }

    function _dcEnvOr(string memory name, address defaultValue) internal view override returns (address) {
        return fakeSet[keccak256(bytes(name))] ? fakeEnv[keccak256(bytes(name))] : defaultValue;
    }

    function resolve(address currentRouter, address currentRla, address currentFee)
        external
        view
        returns (address, address, address)
    {
        return _resolveNewConfig(currentRouter, currentRla, currentFee);
    }
}

/// @notice `SetDynamicConfig` writes the pool's whole dynamic-config struct, so an unset variable must
/// preserve the current on-chain value VERBATIM, `address(0)` included. Anything else turns a
/// one-field update into a silent grant of the others: a broadcaster fallback for zero admins would
/// hand both admin slots to the acting account on a `ROUTER`-only run.
contract SetDynamicConfigPreserveTest is Test {
    DynamicConfigHarness internal harness;

    address internal constant NEW_ROUTER = address(0xA111);
    address internal constant CUR_RLA = address(0xB222);
    address internal constant CUR_FEE = address(0xC333);

    function setUp() public {
        harness = new DynamicConfigHarness();
    }

    /// @dev The defect shape this pins out: ROUTER alone, both admins unset ON CHAIN. The zeros must
    ///      come back verbatim, not become the acting account.
    function test_RouterOnly_PreservesZeroAdminsVerbatim() public {
        harness.setFakeEnv("ROUTER", NEW_ROUTER);

        (address router, address rla, address fee) = harness.resolve(address(0xD00D), address(0), address(0));

        assertEq(router, NEW_ROUTER, "ROUTER override applies");
        assertEq(rla, address(0), "an unset RATE_LIMIT_ADMIN preserves address(0) verbatim");
        assertEq(fee, address(0), "an unset FEE_ADMIN preserves address(0) verbatim");
    }

    function test_NoOverrides_PreservesEverything() public view {
        (address router, address rla, address fee) = harness.resolve(address(0xD00D), CUR_RLA, CUR_FEE);
        assertEq(router, address(0xD00D));
        assertEq(rla, CUR_RLA);
        assertEq(fee, CUR_FEE);
    }

    function test_ExplicitZeroFeeAdmin_IsAppliedNotConfusedWithUnset() public {
        harness.setFakeEnv("FEE_ADMIN", address(0));

        (,, address fee) = harness.resolve(address(0xD00D), CUR_RLA, CUR_FEE);
        assertEq(fee, address(0), "FEE_ADMIN=0x0 is an explicit restrict-to-owner instruction");
    }
}
