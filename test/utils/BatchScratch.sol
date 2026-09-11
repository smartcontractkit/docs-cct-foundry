// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {CctActions} from "../../src/actions/CctActions.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";

/// @title BatchScratch
/// @notice Shared hygiene helper for the tests that emit Safe Transaction Builder batches. `batches/`
/// is an accumulate-and-keep store of the OPERATOR's local run artifacts (gitignored except the
/// committed example), so a suite writing `mint.<chainId>.json` or `accept-ownership.<chainId>.json`
/// buries real artifacts under operator-shaped test output that nothing distinguishes or sweeps.
///
/// Two rules, both enforced here rather than at the call sites:
///   1. Every batch a test emits goes out under the `zz-scratch-` prefix - the repo's test-scratch
///      discipline (see AGENTS.md), the same one `ProjectScratch` applies to the project store. The
///      prefix is applied HERE, not spelled at each call site, so a new emission cannot forget it.
///   2. Every emitted batch is removed BEFORE the first assert that could fail, so a failing
///      assertion cannot strand the artifact either. Batches consumed by `SafeBatchLoader` must be
///      cleaned after the load and before the assertions/execution that follow it.
///
/// The CI "no test residue" gate diffs the whole `batches/` inventory (a fresh checkout holds only
/// the committed example), so a missed cleanup is a red build, not a silent leak.
library BatchScratch {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The prefix every test-emitted batch name carries.
    string internal constant PREFIX = "zz-scratch-";

    /// @notice The scratch batch NAME for `suffix` (what `BATCH_NAME` would be set to).
    function name(string memory suffix) internal pure returns (string memory) {
        return string.concat(PREFIX, suffix);
    }

    /// @notice The scratch batch PATH for `suffix`, mirroring `SafeMode._emitBatch`'s layout. For the
    /// one test that drives the env-reading `SafeMode._run` path and so cannot receive the path back.
    function path(string memory suffix) internal view returns (string memory) {
        return string.concat("batches/", name(suffix), ".", VM.toString(block.chainid), ".json");
    }

    /// @notice Emit `calls` as a Safe batch under the scratch prefix; returns the written path.
    function emitBatch(string memory suffix, address safe, CctActions.Call[] memory calls)
        internal
        returns (string memory)
    {
        return SafeMode._emitBatch(name(suffix), safe, calls);
    }

    /// @notice Remove one emitted batch (revert-safe: a missing file is not an error).
    function clean(string memory batchPath) internal {
        if (VM.exists(batchPath)) VM.removeFile(batchPath);
    }

    /// @notice Remove a set of emitted batches - the composed (`_loadMany`) ceremonies.
    function cleanAll(string[] memory batchPaths) internal {
        for (uint256 i = 0; i < batchPaths.length; i++) {
            clean(batchPaths[i]);
        }
    }
}
