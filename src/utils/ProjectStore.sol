// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ProjectStore
/// @notice Path, skeleton, and schema helpers for the per-chain **project-state store**
/// `project/[<group>/]<selectorName>.json` - the single home for a chain's project state, three
/// subtrees (`addresses{}`, `lanes{}`, `roles{}`) plus a `schema` version, one writer each. The store
/// keys by the canonical CCIP **selectorName**, identical to `config/chains/<selectorName>.json` and
/// `history/<category>/<selectorName>/`, so the three files for a chain share one basename and
/// non-EVM chains (which all report chainId `"0"`) never collide.
///
/// @dev **Token group (optional path segment).** `PROJECT_GROUP` (the `GROUP=` make var) selects one of
/// N token groups in a clone: the file moves to `project/<group>/<selectorName>.json`, its own mesh
/// universe. Unset is the default group - the flat `project/<selectorName>.json`. The name is validated
/// `[a-z0-9][a-z0-9-]*`. All path composition goes through {group}, {path}, and {display}.
///
/// @dev **Canonical form (project/ files): forge `vm.writeJson`'s deterministic output - keys
/// serialized in SORTED order at every nesting level, 2-space indent, and NO trailing newline.**
/// `vm.writeJson` preserves insertion order (it does not sort) and omits the trailing newline, so
/// every writer must insert keys already sorted; a golden test pins the result against
/// `jq --indent 2 -S` with the trailing newline normalized. `make fmt-config` extends here as the
/// REPAIR tool only. The project file is NEVER written with `vm.writeFile` (a whole-file write would
/// clobber sibling subtrees): data writes are targeted
/// `vm.writeJson(value, path, ".addresses"|".lanes"|".roles")`, and the file is bootstrapped with the
/// 2-arg `vm.writeJson(SKELETON, path)` create form only when absent.
///
/// Needs `fs_permissions` read-write on `./project` (covered by the repo's root permission).
library ProjectStore {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The project-state schema version. Future migrations dispatch on this integer rather
    /// than key-sniffing.
    uint256 internal constant SCHEMA = 3;

    /// @dev The canonical empty skeleton: all three subtrees + `schema`, keys in SORTED order
    /// (`addresses` < `lanes` < `roles` < `schema`; `active` < `deployments`) so forge's
    /// insertion-order `writeJson` emits sorted JSON with no post-processing.
    string internal constant SKELETON =
        "{\"addresses\":{\"active\":{},\"deployments\":{}},\"lanes\":{},\"roles\":{},\"schema\":3}";

    /// @notice The selected token group: `PROJECT_GROUP` (empty = the flat default group), validated
    /// `[a-z0-9][a-z0-9-]*`. Reads the env only - never `vm.setEnv` - so it is parallel-safe. Tests that
    /// need a specific group without touching process env pass it explicitly to {pathIn}/{displayIn}.
    function _group() internal view returns (string memory) {
        string memory g = VM.envOr("PROJECT_GROUP", string(""));
        _requireValidGroup(g);
        return g;
    }

    /// @notice Reverts with a named error unless `g` is empty (the flat default) or matches
    /// `[a-z0-9][a-z0-9-]*`. Rejecting `.`, `/`, and `..` also keeps path traversal off the filesystem.
    /// `default` is reserved (it is the label for the flat/unnamed group).
    function _requireValidGroup(string memory g) internal pure {
        bytes memory b = bytes(g);
        if (b.length == 0) return; // unset = flat default group
        require(
            keccak256(b) != keccak256("default"),
            "[project] PROJECT_GROUP 'default' is reserved for the flat (unnamed) group - choose another name"
        );
        bool valid = _isLowerAlnum(b[0]);
        for (uint256 i = 1; valid && i < b.length; i++) {
            valid = _isLowerAlnum(b[i]) || b[i] == "-";
        }
        require(
            valid,
            string.concat(
                "[project] PROJECT_GROUP '",
                g,
                "' is not a valid token-group name - use [a-z0-9][a-z0-9-]* (lowercase letters, digits, and hyphens; first character not a hyphen)"
            )
        );
    }

    function _isLowerAlnum(bytes1 c) private pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "0" && c <= "9");
    }

    /// @dev The store-root-relative path for `selectorName` in group `g` (`g` empty = flat default).
    /// Validates the group so no caller (including a direct `pathIn`/`seedIfAbsentIn` test seam) can
    /// compose a traversal path outside `project/`.
    function _relIn(string memory g, string memory selectorName) internal pure returns (string memory) {
        _requireValidGroup(g);
        if (bytes(g).length == 0) return string.concat("project/", selectorName, ".json");
        return string.concat("project/", g, "/", selectorName, ".json");
    }

    /// @notice The absolute `project/[<group>/]<selectorName>.json` path in group `g` under the project
    /// root - the in-process test seam (pass the group explicitly, no env).
    function _pathIn(string memory g, string memory selectorName) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/", _relIn(g, selectorName));
    }

    /// @notice The user-facing (root-relative) `project/[<group>/]<selectorName>.json` string in group
    /// `g` - for console/log messages that name the file.
    function _displayIn(string memory g, string memory selectorName) internal pure returns (string memory) {
        return _relIn(g, selectorName);
    }

    /// @notice The absolute `project/[<group>/]<selectorName>.json` path under the project root, in the
    /// group selected by `PROJECT_GROUP` (flat default when unset).
    function _path(string memory selectorName) internal view returns (string memory) {
        return _pathIn(_group(), selectorName);
    }

    /// @notice The root-relative `project/[<group>/]<selectorName>.json` for `PROJECT_GROUP` - the one
    /// form every console/log message uses to name the file (byte-identical to the flat path when unset).
    function _display(string memory selectorName) internal view returns (string memory) {
        return _displayIn(_group(), selectorName);
    }

    /// @notice Bootstrap `project/<selectorName>.json` with the full skeleton when it does not yet
    /// exist, so the first targeted subtree write never hits a `vm.writeJson`-cannot-create-a-key
    /// cheatcode revert. A user's first touch of a chain is often `add-lane` or `snapshot-chain`, not
    /// a deploy, so EVERY writer (deploy-record, add-lane, snapshot-chain, adopt-token) calls this
    /// before its subtree write. Idempotent: an existing file is schema-validated and left
    /// byte-identical (never re-seeded over populated subtrees). Uses the 2-arg `vm.writeJson` create
    /// form - never `vm.writeFile` - and only when absent, so it can never clobber a sibling subtree.
    function _seedIfAbsent(string memory selectorName) internal {
        _seedIfAbsentIn(_group(), selectorName);
    }

    /// @notice {seedIfAbsent} for an explicit group `g` - the in-process test seam (no env). Production
    /// callers use {seedIfAbsent}, which resolves the group from `PROJECT_GROUP`.
    function _seedIfAbsentIn(string memory g, string memory selectorName) internal {
        string memory p = _pathIn(g, selectorName);
        if (VM.exists(p)) {
            _requireSchemaIn(g, selectorName);
            return;
        }
        // A grouped file needs its `project/<group>/` directory created first; the flat default writes
        // into the committed `project/` directory.
        if (bytes(g).length != 0) {
            string memory dir = string.concat(VM.projectRoot(), "/project/", g);
            if (!VM.exists(dir)) VM.createDir(dir, true);
        }
        VM.writeJson(SKELETON, p);
    }

    /// @notice Reverts with a NAMED error when `project/<selectorName>.json` is present but is not a
    /// schema-`SCHEMA` document (wrong version, missing `schema`, or not valid JSON) - never a raw
    /// `parseJson` cheatcode revert. Write paths and explicit readers (the doctor's schema rung,
    /// `roles-check`, `adopt-token`) call this; the OPTIONAL address-resolution fallback in
    /// `RegistryWriter._read*` stays tolerant (returns empty, never reverts) so an eager
    /// `HelperConfig` construction racing a parallel test's scratch file is never crashed.
    function _requireSchema(string memory selectorName) internal view {
        _requireSchemaIn(_group(), selectorName);
    }

    /// @notice {requireSchema} for an explicit group `g` - the in-process test seam (no env).
    function _requireSchemaIn(string memory g, string memory selectorName) internal view {
        string memory p = _pathIn(g, selectorName);
        if (!VM.exists(p)) return; // absent is a seed case, not a schema error
        string memory json = VM.readFile(p);
        require(bytes(json).length != 0, string.concat("[project] ", p, " is empty - not valid JSON; fix or delete it"));
        try VM.keyExistsJson(json, ".schema") returns (bool exists) {
            require(
                exists,
                string.concat(
                    "[project] ",
                    p,
                    " has no schema field - not a schema ",
                    VM.toString(SCHEMA),
                    " project file; fix or delete it"
                )
            );
        } catch {
            revert(string.concat("[project] ", p, " is not valid JSON - fix or delete it"));
        }
        uint256 s = VM.parseJsonUint(json, ".schema");
        require(
            s == SCHEMA,
            string.concat(
                "[project] ", p, " is schema ", VM.toString(s), " - unsupported, expected ", VM.toString(SCHEMA)
            )
        );
    }
}
