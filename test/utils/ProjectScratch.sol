// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ProjectScratch
/// @notice Shared hygiene helper for the schema-3 project-state store tests. Every registry/lane/roles
/// test writes into a THROWAWAY `project/zz-scratch-<suite>-<test>.json` and (when a non-default family
/// is needed) a matching `config/chains/zz-scratch-*.json` carrying only `.chainFamily` so
/// `RegistryWriter._validateForFamily` resolves. Both patterns are gitignored
/// (`project/zz-scratch-*.json`, `config/chains/zz-scratch-*.json`), so a leak from a mid-test revert is
/// invisible to `git status` and would deterministically brick a later `forge test` — hence the HARD
/// rule that every suite sweeps ALL its basenames via `clean` in `setUp()` (revert-safe, before the
/// body). A test may ADDITIONALLY remove the fixtures it exclusively owns as its last step (green-path
/// hygiene, so a green run leaves no residue); it must never sweep suite-wide at end-of-test — forge
/// runs a suite's tests in parallel, and a broad end sweep deletes a running sibling's files.
///
/// Basenames MUST be unique per test (`zz-scratch-<suite>-<test>`): `ProjectStore.seedIfAbsent` +
/// forge's parallel suites race silently on a shared basename.
///
/// Test write targets must NEVER use a bundled chain's real selectorName — a stranded fake would be
/// silently resolved by that chain's zero-export ladder on a later script run. Use the
/// `zz-scratch-*` / `zz-tt-*` / `local-*` prefixes; the CI "no test residue (any filename)"
/// inventory gate enforces the no-residue invariant.
library ProjectScratch {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function projectPath(string memory selectorName) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/project/", selectorName, ".json");
    }

    function configPath(string memory selectorName) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/config/chains/", selectorName, ".json");
    }

    /// @notice Write a COMPLETE, discovery-safe scratch chain-config for a `zz-scratch-*` selectorName.
    /// It MUST carry every field `HelperConfig`'s construction-time scan (`ChainConfig.tryLoad` →
    /// `_parse`) reads — a minimal `{chainFamily}` stub would revert that scan (`parseJsonUint
    /// ".chainSelector"`) and crash EVERY parallel `HelperConfig` construction, not just this suite's.
    /// EVM scratch tests that only exercise the store need no config (`RegistryWriter._family`
    /// defaults to EVM when the config is absent); seed an EVM config only when the test resolves the
    /// chain THROUGH `HelperConfig` (chainId → selectorName / `{CHAIN}_` env rungs). `chainId` is "0"
    /// for svm. `chainSelector`/`chainId` must be unique (outside any real chain) to avoid a discovery
    /// collision. `chainNameIdentifier` derives from the selectorName (uppercase, `-` → `_`) so each
    /// scratch chain gets a distinct `{CHAIN}_` env prefix.
    function seedConfig(string memory selectorName, string memory family, uint256 chainId, uint64 chainSelector)
        internal
    {
        // Built as a raw JSON string (NOT vm.serialize*): forge's serialization journal is keyed by the
        // object handle and accumulates across calls, so reusing a handle across tests can emit an
        // inconsistent (even empty) document — which then makes `_family`'s `parseJsonString` revert EOF.
        // A raw string is deterministic per call.
        string memory json = string.concat(
            "{",
            '"ccip":{',
            '"feeQuoter":"0x0000000000000000000000000000000000000006",',
            '"feeTokens":[],',
            '"link":"0x0000000000000000000000000000000000000001",',
            '"registryModuleOwnerCustom":"0x0000000000000000000000000000000000000004",',
            '"rmnProxy":"0x0000000000000000000000000000000000000003",',
            '"router":"0x0000000000000000000000000000000000000002",',
            '"tokenAdminRegistry":"0x0000000000000000000000000000000000000005",',
            '"tokenPoolFactory":"0x0000000000000000000000000000000000000007"},',
            '"chainFamily":"',
            family,
            '","chainId":"',
            VM.toString(chainId),
            '","chainNameIdentifier":"',
            identifierFor(selectorName),
            '",',
            '"chainSelector":"',
            VM.toString(chainSelector),
            '",',
            '"displayName":"Scratch",',
            '"environment":"testnet",',
            '"explorerUrl":"https://example.invalid",',
            '"name":"',
            selectorName,
            '","nativeCurrencySymbol":"ZZZ",',
            '"rpcEnv":"ZZ_SCRATCH_RPC_URL"}'
        );
        VM.writeFile(configPath(selectorName), json);
    }

    /// @notice The `{CHAIN}_` env prefix for a scratch selectorName: uppercase, `-` → `_` (the same
    /// derivation `sync-discover.sh` applies to real chains).
    function identifierFor(string memory selectorName) internal pure returns (string memory) {
        // Copy first: `bytes(<string memory>)` ALIASES the caller's buffer, so an in-place
        // transform would silently uppercase the caller's selectorName too.
        bytes memory src = bytes(selectorName);
        bytes memory b = new bytes(src.length);
        for (uint256 i = 0; i < src.length; i++) {
            if (src[i] == "-") {
                b[i] = "_";
            } else if (src[i] >= "a" && src[i] <= "z") {
                b[i] = bytes1(uint8(src[i]) - 32);
            } else {
                b[i] = src[i];
            }
        }
        return string(b);
    }

    /// @notice Remove BOTH the scratch project file and the scratch config file (for a `zz-scratch-*`
    /// selectorName this suite owns end-to-end). Revert-safe; call from `setUp()`.
    function clean(string memory selectorName) internal {
        string memory p = projectPath(selectorName);
        if (VM.exists(p)) VM.removeFile(p);
        string memory c = configPath(selectorName);
        if (VM.exists(c)) VM.removeFile(c);
    }

    /// @notice Remove ONLY the project file, leaving a REAL (committed) `config/chains/<name>.json`
    /// intact — for tests that resolve a real configured chain's selectorName through `HelperConfig`.
    function cleanProject(string memory selectorName) internal {
        string memory p = projectPath(selectorName);
        if (VM.exists(p)) VM.removeFile(p);
    }

    /// @notice Directory-shaped cleanup for a token-group subtree `project/<group>/` (revert-safe; call
    /// from setUp()). A grouped project file lives at `project/<group>/<selectorName>.json`; the whole
    /// `zz-scratch-*` group directory is gitignored (`project/zz-scratch-*/`), so a leaked dir from a
    /// mid-test revert is invisible to `git status` yet would poison a later "no stray group dir"
    /// assertion — the same HARD setUp() rule as the flat store. Removes the group directory and
    /// everything under it.
    function cleanGroupDir(string memory group) internal {
        string memory d = string.concat(VM.projectRoot(), "/project/", group);
        if (VM.exists(d)) VM.removeDir(d, true);
    }

    /// @notice Directory-shaped cleanup for the append-only `history/<category>/<selectorName>/` ledger:
    /// removes the per-artifact scratch directory under EVERY category (revert-safe; call from setUp()).
    /// The ledger dirs are gitignored (`history/`), so a leaked scratch dir from a mid-test revert is
    /// invisible to `git status` yet would poison a later "append-only / no stray dir" assertion — hence
    /// the same HARD setUp() rule as the project store.
    function cleanHistory(string memory selectorName) internal {
        string[4] memory categories = ["tokens", "token-pools", "lock-boxes", "advanced-pool-hooks"];
        for (uint256 i = 0; i < categories.length; i++) {
            string memory d = string.concat(VM.projectRoot(), "/history/", categories[i], "/", selectorName);
            if (VM.exists(d)) VM.removeDir(d, true);
        }
    }
}
