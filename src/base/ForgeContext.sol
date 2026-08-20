// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @title ForgeContext
/// @notice Whether the calls a script records will actually be sent, in ONE place.
/// @dev `forge script` runs the body as a SIMULATION and dispatches the recorded transactions only
///      after it returns; `vm.startBroadcast()` records, it does not send. Two decisions hang on the
///      same question - whether the deployed-address store may be written (`RegistryWriter._record`)
///      and what the run may claim it did (`OutcomeLog`). Asked separately they can disagree, and the
///      result is a phantom record: a deployment written to the store for a run the operator was told
///      sent nothing, or the reverse. The deploy scripts and `SafeMode` broadcast directly without
///      inheriting the executor, so when this check lived in the executor those thirteen call sites
///      announced a send during a dry run - the path most often run without `--broadcast`.
library ForgeContext {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice True when this run sends nothing: a dry run (`forge script` with no `--broadcast`) or a
    ///         test. False under `--broadcast` and under `--resume`, which redispatches a failed batch.
    function _sendsNothing() internal view returns (bool) {
        return !VM.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !VM.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
