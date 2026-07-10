// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DepositToLockBox} from "../../script/operations/DepositToLockBox.s.sol";

/// @dev Harness that forces the lockbox to resolve NOWHERE, regardless of the process-wide env. This is
/// the deterministic "explicit input" the revert path needs: the previous fork test skipped whenever a
/// parallel suite had set `LOCK_BOX` (a process-wide `vm.setEnv`), so ~2 of 3 runs it asserted nothing.
/// Overriding the resolution seam removes ALL env dependence, so the revert is exercised on every run.
contract DepositToLockBoxUnresolvedHarness is DepositToLockBox {
    function _resolveLockBox(uint256) internal pure override returns (address) {
        return address(0);
    }
}

/// @notice `DepositToLockBox` moved from a REQUIRED `vm.envAddress("LOCK_BOX")` (which reverted with a
/// raw cheatcode error) to the standard resolution ladder (`LOCK_BOX` > `{CHAIN}_LOCK_BOX` > registry
/// `active.lockBox`). When the lockbox resolves NOWHERE it must still fail — but with the clear,
/// self-explaining message, never silently proceed with `address(0)`.
/// @dev No fork, no env, no skip: the harness pins the resolution to `address(0)`, so this asserts the
/// named revert deterministically on every run. `vm.chainId` is set to a CONFIGURED chain so the earlier
/// `getChainName(block.chainid)` in `run()` resolves before the lockbox `require` fires.
contract DepositToLockBoxTest is Test {
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11155111;

    function test_DepositToLockBox_RevertsWithNamedMessageWhenUnresolved() public {
        vm.chainId(ETHEREUM_SEPOLIA_CHAIN_ID);
        DepositToLockBox script = new DepositToLockBoxUnresolvedHarness();
        vm.expectRevert(bytes("LockBox not deployed. Set LOCK_BOX or the {CHAIN}_LOCK_BOX environment variable."));
        script.run();
    }
}
