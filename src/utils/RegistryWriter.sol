// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {ProjectStore} from "./ProjectStore.sol";
import {ChainHandlers} from "../../script/utils/ChainHandlers.s.sol";

/// @title RegistryWriter
/// @notice The deployed-address registry: the `addresses{}` sub-store of
/// `project/<selectorName>.json`. Deploy scripts record their outputs here - one project file per
/// chain, keyed by the canonical CCIP **selectorName** (identical to `config/chains/<selectorName>.json`)
/// - so a fresh deployment is immediately resolvable by every later script with no `export` step: the
/// store survives the terminal session that shell exports vanish with. Environment variables (`TOKEN`,
/// `{CHAIN}_TOKEN`, ...) keep working and always take priority over the store (an env-driven run is
/// READ-ONLY - it never writes back; the divergence notice names the reconcile command instead).
///
/// @dev **Schema 3 - `active` role pointers + named `deployments` entries, both STRING-valued.**
/// ```jsonc
/// // project/<selectorName>.json
/// {
///   "addresses": {
///     "active": {                        // what HelperConfig resolves (zero-export)
///       "token": "0x..", "tokenPool": "0x.."   // EVM hex, or non-EVM base58 (e.g. a Solana pool)
///     },
///     "deployments": {                   // uniquely named per artifact (type + version in the key)
///       "BnM-T_Token": "0x..",
///       "BnM-T_BurnMintTokenPool_2.0.0": "0x.."
///     }
///   },
///   "lanes": { ... }, "roles": { ... }, "schema": 3
/// }
/// ```
/// Values are **family-validated strings** on write (EVM hex, or non-EVM base58 that base58-decodes to
/// exactly 32 bytes - via `ChainHandlers`), so a project's non-EVM remote artifacts (the Solana token
/// and pool an EVM pool's `applyChainUpdates` needs) live in the reviewed project file, not an ephemeral
/// env var. `read(selectorName, role)` resolves `.addresses.active.<role>` (as an EVM `address`);
/// `readString` returns the raw value for non-EVM resolution.
///
/// **Every write is subtree-isolated.** All writes go through targeted `vm.writeJson(_, path,
/// ".addresses")`; the whole-file `vm.writeFile` is FORBIDDEN, because `addresses`/`lanes`/`roles`
/// share one file and a whole-file write would clobber the sibling subtrees. The project file is
/// seeded (all three subtrees) by `ProjectStore._seedIfAbsent` before any targeted write.
///
/// Needs `fs_permissions` read-write on `./project` (covered by the repo's root permission).
library RegistryWriter {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ─────────────────────────────────────────────────────────────────────────
    // Script-facing wrappers (context-aware)
    //
    // The registry is a durable store of REAL deployments, so the script-facing
    // entry points sense the forge execution context:
    //   - `forge test`                → both are no-ops (test fixtures rerun the deploy
    //                                   scripts constantly; simulations must not mutate
    //                                   or be blocked by the durable store)
    //   - `forge script` (dry run)   → `guard` is active (the dry run previews exactly
    //                                   what the broadcast would do) but `record` does
    //                                   not write (a simulation is not a deployment)
    //   - `forge script --broadcast` → both are active
    // The deterministic cores below (`guardRedeploy`/`recordDeterministic`/`set*`/`read*`) never look
    // at the context, so tests can drive every branch directly.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Script-facing idempotency guard - call BEFORE `vm.startBroadcast()`. `deploymentName`
    /// is the unique `deployments` key (e.g. `BnM-T_BurnMintTokenPool_2.0.0`).
    function _guard(string memory selectorName, string memory deploymentName) internal {
        if (VM.isContext(VmSafe.ForgeContext.TestGroup)) return;
        _guardRedeploy(selectorName, deploymentName);
    }

    /// @notice Script-facing single-writer registry write - call after the deployment succeeds. Upserts
    /// BOTH the named `deployments[deploymentName]` entry AND the `active[role]` pointer in one call.
    /// Only a real broadcast (`--broadcast` / `--resume`) mutates the store.
    function _record(string memory selectorName, string memory role, string memory deploymentName, address addr)
        internal
    {
        if (!VM.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !VM.isContext(VmSafe.ForgeContext.ScriptResume)) {
            return;
        }
        _recordDeterministic(selectorName, role, deploymentName, addr);
    }

    /// @notice Deploy idempotency guard (deterministic core entry). If `deploymentName` already
    /// resolves to a non-zero address in the store's `deployments`, REFUSE (revert naming the existing
    /// address and the exact override) unless env `FORCE_REDEPLOY=true`. When forced, the stale entry is
    /// dropped from `deployments` (the replaced address stays in the append-only ledger under `history/`;
    /// the project store itself is gitignored, so it is NOT in git history) so the post-deploy `record`
    /// registers the replacement. First-time flows (no project file / no entry for `deploymentName`) are
    /// complete no-ops.
    function _guardRedeploy(string memory selectorName, string memory deploymentName) internal {
        _guardRedeploy(selectorName, deploymentName, VM.envOr("FORCE_REDEPLOY", false));
    }

    /// @dev Deterministic core (the env read is split out so tests can exercise both the refuse and
    /// the force branches without toggling `FORCE_REDEPLOY` - `vm.setEnv` is process-wide and would
    /// race parallel test suites).
    function _guardRedeploy(string memory selectorName, string memory deploymentName, bool forced) internal {
        address existing = _readDeployment(selectorName, deploymentName);
        if (existing == address(0)) return; // first-time flow: nothing registered under this name

        string memory path = ProjectStore._path(selectorName);
        if (!forced) {
            revert(
                string.concat(
                    "RegistryWriter: '",
                    deploymentName,
                    "' is already deployed at ",
                    VM.toString(existing),
                    " (",
                    path,
                    "). Refusing to redeploy - set FORCE_REDEPLOY=true to deploy a replacement."
                )
            );
        }
        console.log("FORCE_REDEPLOY=true:", deploymentName, "will be replaced in the store; old address:");
        console.log("  ", existing, "(stays in the append-only ledger: history/)");
        _dropDeployment(selectorName, deploymentName); // drop the stale entry so record() registers the replacement
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reads (optional fallback - NEVER revert)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Resolves a ROLE (`token`/`tokenPool`/`lockBox`/`poolHooks`) to the currently-active
    /// address from `.addresses.active.<role>` as an EVM `address`. `address(0)` when the file/key is
    /// absent OR the stored value is a non-EVM (base58) string (an EVM caller resolving a non-EVM chain);
    /// use `readString` for the raw non-EVM value. Never reverts - callers treat the store as an
    /// optional fallback.
    function _read(string memory selectorName, string memory role) internal view returns (address) {
        string memory s = _readString(selectorName, role);
        if (bytes(s).length == 0) return address(0);
        try VM.parseAddress(s) returns (address a) {
            return a;
        } catch {
            return address(0); // non-EVM (base58) value read through the EVM getter
        }
    }

    /// @notice Resolves a ROLE to its RAW stored string (EVM hex or non-EVM base58). Empty string when
    /// the file or the key is absent. Never reverts (see `read`). This is the non-EVM resolution path
    /// the frozen EVM getter surface (`read`) cannot serve.
    function _readString(string memory selectorName, string memory role) internal view returns (string memory) {
        string memory json = _readProjectJson(selectorName);
        if (bytes(json).length == 0) return "";
        string memory activeKey = string.concat(".addresses.active.", role);
        try VM.keyExistsJson(json, activeKey) returns (bool exists) {
            if (exists) return VM.parseJsonString(json, activeKey);
        } catch {
            return "";
        }
        return "";
    }

    /// @notice Resolves a uniquely-named `deployments` entry (e.g. a specific pool type + version) as
    /// an EVM `address`. `address(0)` when the file or the key is absent (never reverts).
    function _readDeployment(string memory selectorName, string memory deploymentName) internal view returns (address) {
        string memory s = _readDeploymentString(selectorName, deploymentName);
        if (bytes(s).length == 0) return address(0);
        try VM.parseAddress(s) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /// @notice The RAW stored string of a named `deployments` entry (EVM hex or non-EVM base58). Empty
    /// when the file or the key is absent (never reverts).
    function _readDeploymentString(string memory selectorName, string memory deploymentName)
        internal
        view
        returns (string memory)
    {
        string memory json = _readProjectJson(selectorName);
        if (bytes(json).length == 0) return "";
        // Bracket notation: version keys (e.g. `..._2.0.0`) contain dots, which dot-path notation would
        // mis-split. `["<key>"]` treats the whole name as one literal key.
        string memory key = string.concat(".addresses.deployments[\"", deploymentName, "\"]");
        try VM.keyExistsJson(json, key) returns (bool exists) {
            if (exists) return VM.parseJsonString(json, key);
        } catch {
            return "";
        }
        return "";
    }

    /// @dev TOCTOU-safe optional read of `project/<selectorName>.json` - a parallel test suite can
    /// remove or be mid-write to this file between checks (`vm.writeJson` truncates then writes), so a
    /// vanished/empty/partial snapshot resolves to "" rather than crashing an unrelated suite that
    /// merely constructed HelperConfig. The store is an OPTIONAL fallback that must NEVER revert.
    function _readProjectJson(string memory selectorName) private view returns (string memory) {
        string memory path = ProjectStore._path(selectorName);
        if (!VM.exists(path)) return "";
        try VM.readFile(path) returns (string memory data) {
            return data;
        } catch {
            return "";
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Writes (subtree-isolated - NEVER writeFile the project file)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Upserts the `active[role]` pointer, preserving every other entry. EVM convenience
    /// wrapper (address → validated hex string).
    function _setActive(string memory selectorName, string memory role, address addr) internal {
        _setActiveString(selectorName, role, VM.toString(addr));
    }

    /// @notice Upserts the `active[role]` pointer with a raw (family-validated) string value - the
    /// non-EVM (base58) write path.
    function _setActiveString(string memory selectorName, string memory role, string memory value) internal {
        ProjectStore._seedIfAbsent(selectorName);
        _validateForFamily(selectorName, value);
        _warnRepoint(selectorName, role, value);
        (string[] memory aKeys, string[] memory aVals, string[] memory dKeys, string[] memory dVals) =
            _loadMaps(selectorName);
        (aKeys, aVals) = _upsert(aKeys, aVals, role, value);
        _store(selectorName, aKeys, aVals, dKeys, dVals);
        console.log(
            string.concat("Store updated: ", ProjectStore._display(selectorName), " (addresses.active.", role, ")")
        );
    }

    /// @notice Deterministic view helper: would setting (`selectorName`, `role`, `value`) REPOINT the
    /// zero-export `active[role]` pointer onto a DIFFERENT value? Returns (`repoints`, `previous`) where
    /// `previous` is the current raw `active[role]` ("" when unset) and `repoints` is true ONLY when a
    /// non-empty pointer already exists and differs from `value`. First set and idempotent re-set are
    /// NOT repoints. Pure of side effects so the write paths gate the repoint warning on it and unit
    /// tests can assert it directly.
    function _wouldRepointActive(string memory selectorName, string memory role, string memory value)
        internal
        view
        returns (bool repoints, string memory previous)
    {
        previous = _readString(selectorName, role);
        repoints = bytes(previous).length != 0 && keccak256(bytes(previous)) != keccak256(bytes(value));
    }

    /// @dev Warn LOUDLY (console only, no behavior change) when an `active[role]` pointer is about to
    /// be silently repointed onto a different address - e.g. deploying a second token on a chain moves
    /// `active.token` off the first fixture, hijacking the zero-export pointer every no-override script
    /// resolves. The repoint still happens; the operator is told how to pin the previous address -
    /// **naming the token group first** (a second token belongs in its own group, which leaves this
    /// store untouched), then the store-native re-adopt, then the env one-off. Never fires on a first set
    /// or idempotent re-set (see `wouldRepointActive`). Both write paths that touch `active[role]`
    /// (`setActiveString`/`recordDeterministicString`) route through here.
    function _warnRepoint(string memory selectorName, string memory role, string memory value) private view {
        (bool repoints, string memory previous) = _wouldRepointActive(selectorName, role, value);
        if (!repoints) return;
        string memory env = _roleEnvVar(role);
        console.log(
            string.concat("WARNING: active.", role, " repointed ", previous, " -> ", value, " on ", selectorName, ".")
        );
        console.log(string.concat("         Scripts with no env override will now resolve ", value, "."));
        console.log(
            string.concat(
                "         A second token here belongs in its own group (a grouped rerun would have left this store untouched): make adopt-token CHAIN=",
                selectorName,
                " TOKEN=",
                value,
                " GROUP=<g>"
            )
        );
        console.log(
            string.concat(
                "         To keep the previous one active here, re-adopt it: make adopt-token CHAIN=",
                selectorName,
                " TOKEN=",
                previous,
                " (it stays in deployments; find earlier artifacts under .addresses.deployments)."
            )
        );
        console.log(
            string.concat(
                "         Or for a one-off run, override read-only: ",
                env,
                "=",
                previous,
                " (or ",
                selectorName,
                "_",
                env,
                "=",
                previous,
                ") - this does NOT write the store back."
            )
        );
    }

    /// @dev Maps a camelCase registry role to the UPPER_SNAKE env-var stem HelperConfig reads as the
    /// override (`token`->`TOKEN`, `tokenPool`->`TOKEN_POOL`, `lockBox`->`LOCK_BOX`,
    /// `poolHooks`->`POOL_HOOKS`); the chain-scoped form is `<CHAIN>_<stem>`.
    function _roleEnvVar(string memory role) private pure returns (string memory) {
        bytes memory b = bytes(role);
        bytes memory out = new bytes(b.length * 2);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch >= "A" && ch <= "Z") {
                if (i != 0) {
                    out[j++] = "_";
                }
                out[j++] = ch;
            } else if (ch >= "a" && ch <= "z") {
                out[j++] = bytes1(uint8(ch) - 32);
            } else {
                out[j++] = ch;
            }
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 i = 0; i < j; i++) {
            trimmed[i] = out[i];
        }
        return string(trimmed);
    }

    /// @notice Upserts a named `deployments[deploymentName]` entry, preserving every other entry. EVM
    /// convenience wrapper.
    function _setDeployment(string memory selectorName, string memory deploymentName, address addr) internal {
        _setDeploymentString(selectorName, deploymentName, VM.toString(addr));
    }

    /// @notice Upserts a named `deployments[deploymentName]` entry with a raw (family-validated) string.
    function _setDeploymentString(string memory selectorName, string memory deploymentName, string memory value)
        internal
    {
        ProjectStore._seedIfAbsent(selectorName);
        _validateForFamily(selectorName, value);
        (string[] memory aKeys, string[] memory aVals, string[] memory dKeys, string[] memory dVals) =
            _loadMaps(selectorName);
        (dKeys, dVals) = _upsert(dKeys, dVals, deploymentName, value);
        _store(selectorName, aKeys, aVals, dKeys, dVals);
        console.log(
            string.concat(
                "Store updated: ", ProjectStore._display(selectorName), " (addresses.deployments.", deploymentName, ")"
            )
        );
    }

    /// @notice Back-compat alias: records a ROLE pointer (writes `active[role]`). Retained so callers
    /// that only need the resolvable-pointer semantics (and the resolution tests) keep working.
    function _set(string memory selectorName, string memory role, address addr) internal {
        _setActive(selectorName, role, addr);
    }

    /// @notice Deterministic single-writer core (EVM): upserts `deployments[deploymentName]` AND
    /// `active[role]` in ONE subtree write. This is the anti-duplication write the deploy scripts route
    /// every artifact through (via `record`).
    function _recordDeterministic(
        string memory selectorName,
        string memory role,
        string memory deploymentName,
        address addr
    ) internal {
        _recordDeterministicString(selectorName, role, deploymentName, VM.toString(addr));
    }

    /// @notice Deterministic single-writer core with a raw (family-validated) string value - the
    /// non-EVM (base58) declare/adopt path. Upserts both `deployments[deploymentName]` and
    /// `active[role]` in one subtree write, so the two can never drift apart.
    function _recordDeterministicString(
        string memory selectorName,
        string memory role,
        string memory deploymentName,
        string memory value
    ) internal {
        ProjectStore._seedIfAbsent(selectorName);
        _validateForFamily(selectorName, value);
        _warnRepoint(selectorName, role, value);
        (string[] memory aKeys, string[] memory aVals, string[] memory dKeys, string[] memory dVals) =
            _loadMaps(selectorName);
        (dKeys, dVals) = _upsert(dKeys, dVals, deploymentName, value);
        (aKeys, aVals) = _upsert(aKeys, aVals, role, value);
        _store(selectorName, aKeys, aVals, dKeys, dVals);
        console.log(
            string.concat(
                "Store updated: ",
                ProjectStore._display(selectorName),
                " (addresses.deployments.",
                deploymentName,
                " + addresses.active.",
                role,
                ")"
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Family validation (EVM hex / non-EVM base58) - reads the chain's declared family
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Validates that `value` is a syntactically valid address for the chain's declared
    /// `chainFamily` (EVM hex, or SVM base58 that decodes to exactly 32 bytes). The family is read from
    /// `config/chains/<selectorName>.json`; when no config file exists (a bare unit-test scratch chain)
    /// EVM/hex is assumed. Reverts with a NAMED error on a family mismatch (hex on SVM, base58 on EVM)
    /// or malformed value, never a raw cheatcode revert.
    function _validateForFamily(string memory selectorName, string memory value) private view {
        ChainHandlers.ChainFamily fam = _family(selectorName);
        require(
            ChainHandlers._validateChainAddress(value, fam),
            string.concat(
                "[project] '",
                value,
                "' is not a valid ",
                fam == ChainHandlers.ChainFamily.EVM ? "EVM (0x + 40 hex)" : "SVM (base58, 32 bytes)",
                " address for ",
                selectorName
            )
        );
    }

    function _family(string memory selectorName) private view returns (ChainHandlers.ChainFamily) {
        string memory cfg = string.concat(VM.projectRoot(), "/config/chains/", selectorName, ".json");
        if (!VM.exists(cfg)) return ChainHandlers.ChainFamily.EVM;
        try VM.readFile(cfg) returns (string memory json) {
            return ChainHandlers._parseChainFamily(VM.parseJsonString(json, ".chainFamily"));
        } catch {
            return ChainHandlers.ChainFamily.EVM;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal (de)serialization - canonical (sorted keys, 2-space via writeJson, no trailing newline)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Drops `deploymentName` from `deployments` and clears any `active[role]` that pointed at the
    /// dropped value (so a forced redeploy leaves no dangling active pointer).
    function _dropDeployment(string memory selectorName, string memory deploymentName) private {
        (string[] memory aKeys, string[] memory aVals, string[] memory dKeys, string[] memory dVals) =
            _loadMaps(selectorName);

        string memory dropped = "";
        for (uint256 i = 0; i < dKeys.length; i++) {
            if (keccak256(bytes(dKeys[i])) == keccak256(bytes(deploymentName))) {
                dropped = dVals[i];
                break;
            }
        }
        (dKeys, dVals) = _remove(dKeys, dVals, deploymentName);
        if (bytes(dropped).length != 0) {
            (aKeys, aVals) = _removeByValue(aKeys, aVals, dropped);
        }
        _store(selectorName, aKeys, aVals, dKeys, dVals);
    }

    function _loadMaps(string memory selectorName)
        private
        view
        returns (string[] memory aKeys, string[] memory aVals, string[] memory dKeys, string[] memory dVals)
    {
        string memory path = ProjectStore._path(selectorName);
        if (!VM.exists(path)) {
            return (new string[](0), new string[](0), new string[](0), new string[](0));
        }
        string memory json = VM.readFile(path);
        (aKeys, aVals) = _readObj(json, ".addresses.active");
        (dKeys, dVals) = _readObj(json, ".addresses.deployments");
    }

    function _readObj(string memory json, string memory objPath)
        private
        view
        returns (string[] memory keys, string[] memory vals)
    {
        if (!VM.keyExistsJson(json, objPath)) {
            return (new string[](0), new string[](0));
        }
        keys = VM.parseJsonKeys(json, objPath);
        vals = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            // Bracket notation so keys containing dots (versioned pool names) are read as one literal key.
            vals[i] = VM.parseJsonString(json, string.concat(objPath, "[\"", keys[i], "\"]"));
        }
    }

    /// @dev Writes the `.addresses` subtree only (targeted `vm.writeJson`, never `writeFile`), keys in
    /// SORTED order at every level so forge's insertion-order serialization is byte-canonical.
    function _store(
        string memory selectorName,
        string[] memory aKeys,
        string[] memory aVals,
        string[] memory dKeys,
        string[] memory dVals
    ) private {
        (aKeys, aVals) = _sort(aKeys, aVals);
        (dKeys, dVals) = _sort(dKeys, dVals);
        // Compact JSON with explicitly-quoted string values; `active` before `deployments` (sorted).
        string memory addresses =
            string.concat("{\"active\":", _obj(aKeys, aVals), ",\"deployments\":", _obj(dKeys, dVals), "}");
        VM.writeJson(addresses, ProjectStore._path(selectorName), ".addresses");
    }

    /// @dev Serializes a `{key:"value"}` object as compact, sorted, string-valued JSON. Every value is
    /// force-quoted so a numeric-looking address string can never be emitted as a JSON number.
    function _obj(string[] memory keys, string[] memory vals) private pure returns (string memory) {
        if (keys.length == 0) return "{}";
        string memory inner = "";
        for (uint256 i = 0; i < keys.length; i++) {
            inner = string.concat(inner, i == 0 ? "" : ",", "\"", keys[i], "\":\"", vals[i], "\"");
        }
        return string.concat("{", inner, "}");
    }

    /// @dev Insertion sort of (keys, vals) by byte-lexicographic key order - matches `jq -S` for the
    /// ASCII keys the store uses (role names, symbol_type_version deployment names). Small arrays.
    function _sort(string[] memory keys, string[] memory vals) private pure returns (string[] memory, string[] memory) {
        for (uint256 i = 1; i < keys.length; i++) {
            string memory k = keys[i];
            string memory v = vals[i];
            uint256 j = i;
            while (j > 0 && _lessThan(k, keys[j - 1])) {
                keys[j] = keys[j - 1];
                vals[j] = vals[j - 1];
                j--;
            }
            keys[j] = k;
            vals[j] = v;
        }
        return (keys, vals);
    }

    /// @dev Byte-lexicographic `a < b` (shorter prefix sorts first), matching `jq -S`'s key ordering
    /// for ASCII keys.
    function _lessThan(string memory a, string memory b) private pure returns (bool) {
        bytes memory ba = bytes(a);
        bytes memory bb = bytes(b);
        uint256 n = ba.length < bb.length ? ba.length : bb.length;
        for (uint256 i = 0; i < n; i++) {
            if (ba[i] != bb[i]) return uint8(ba[i]) < uint8(bb[i]);
        }
        return ba.length < bb.length;
    }

    function _upsert(string[] memory keys, string[] memory vals, string memory key, string memory val)
        private
        pure
        returns (string[] memory, string[] memory)
    {
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) {
                vals[i] = val;
                return (keys, vals);
            }
        }
        string[] memory nk = new string[](keys.length + 1);
        string[] memory nv = new string[](keys.length + 1);
        for (uint256 i = 0; i < keys.length; i++) {
            nk[i] = keys[i];
            nv[i] = vals[i];
        }
        nk[keys.length] = key;
        nv[keys.length] = val;
        return (nk, nv);
    }

    function _remove(string[] memory keys, string[] memory vals, string memory key)
        private
        pure
        returns (string[] memory, string[] memory)
    {
        uint256 n = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) != keccak256(bytes(key))) n++;
        }
        string[] memory nk = new string[](n);
        string[] memory nv = new string[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) continue;
            nk[j] = keys[i];
            nv[j] = vals[i];
            j++;
        }
        return (nk, nv);
    }

    function _removeByValue(string[] memory keys, string[] memory vals, string memory val)
        private
        pure
        returns (string[] memory, string[] memory)
    {
        uint256 n = 0;
        for (uint256 i = 0; i < vals.length; i++) {
            if (keccak256(bytes(vals[i])) != keccak256(bytes(val))) n++;
        }
        string[] memory nk = new string[](n);
        string[] memory nv = new string[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(vals[i])) == keccak256(bytes(val))) continue;
            nk[j] = keys[i];
            nv[j] = vals[i];
            j++;
        }
        return (nk, nv);
    }
}
