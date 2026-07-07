// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @title RegistryWriter
/// @notice The deployed-address registry: deploy scripts record their outputs in
/// `addresses/<chainId>.json`, one file per chain, so a fresh deployment is immediately resolvable
/// by every later script with no `export` step — the registry survives the terminal session that
/// shell exports vanish with. Environment variables (`TOKEN`, `{CHAIN}_TOKEN`, ...) keep working and
/// always take priority over the registry.
///
/// @dev **Schema v2 — `active` role pointers + named `deployments` entries.**
/// ```jsonc
/// {
///   "active": {                        // what HelperConfig resolves (zero-export)
///     "token": "0x..", "tokenPool": "0x..", "lockBox": "0x..", "poolHooks": "0x.."
///   },
///   "deployments": {                   // uniquely named per artifact (type + version in the key)
///     "BnM-T_Token": "0x..",
///     "BnM-T_BurnMintTokenPool_2.0.0": "0x..",
///     "BnM-T_LockBox": "0x..",
///     "BnM-T_BurnMint_PoolHooks": "0x.."
///   }
/// }
/// ```
/// `read(chainId, role)` resolves `.active.<role>` (with a legacy fallback to a flat top-level
/// `.<role>` so any pre-v2 runtime file keeps resolving). The redeploy guard keys on the unique
/// `deployments` name: because the key includes the pool's TYPE and VERSION, distinct artifacts never
/// collide (a different type or version is a different key and records freely), while re-deploying the
/// *same* name is guarded and needs `FORCE_REDEPLOY=true`. Note the deploy scripts pin the pool version
/// (`DeploymentRecorder.POOL_VERSION` = "2.0.0"), so the scripts only ever emit the `_2.0.0` key.
///
/// Needs `fs_permissions` read-write on `./addresses` (covered by the repo's root permission).
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

    /// @notice Script-facing idempotency guard — call BEFORE `vm.startBroadcast()`. `deploymentName`
    /// is the unique `deployments` key (e.g. `BnM-T_BurnMintTokenPool_2.0.0`).
    function guard(uint256 chainId, string memory deploymentName) internal {
        if (VM.isContext(VmSafe.ForgeContext.TestGroup)) return;
        guardRedeploy(chainId, deploymentName);
    }

    /// @notice Script-facing single-writer registry write — call after the deployment succeeds. Upserts
    /// BOTH the named `deployments[deploymentName]` entry AND the `active[role]` pointer in one call.
    /// Only a real broadcast (`--broadcast` / `--resume`) mutates the registry.
    function record(uint256 chainId, string memory role, string memory deploymentName, address addr) internal {
        if (!VM.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !VM.isContext(VmSafe.ForgeContext.ScriptResume)) {
            return;
        }
        recordDeterministic(chainId, role, deploymentName, addr);
    }

    /// @notice Deploy idempotency guard (deterministic core entry). If `deploymentName` already
    /// resolves to a non-zero address in `addresses/<chainId>.json` `deployments`, REFUSE (revert
    /// naming the existing address and the exact override) unless env `FORCE_REDEPLOY=true`. When
    /// forced, the stale entry is dropped from `deployments` (the old address stays in the append-only
    /// ledger under `script/deployments/`; note the registry itself is gitignored, so it is NOT in git
    /// history) so the post-deploy `record` registers the replacement.
    /// First-time flows (no registry file / no entry for `deploymentName`) are complete no-ops.
    function guardRedeploy(uint256 chainId, string memory deploymentName) internal {
        guardRedeploy(chainId, deploymentName, VM.envOr("FORCE_REDEPLOY", false));
    }

    /// @dev Deterministic core (the env read is split out so tests can exercise both the refuse and
    /// the force branches without toggling `FORCE_REDEPLOY` — `vm.setEnv` is process-wide and would
    /// race parallel test suites).
    function guardRedeploy(uint256 chainId, string memory deploymentName, bool forced) internal {
        address existing = readDeployment(chainId, deploymentName);
        if (existing == address(0)) return; // first-time flow: nothing registered under this name

        string memory path = _path(chainId);
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
        console.log("FORCE_REDEPLOY=true:", deploymentName, "will be replaced in the registry; old address:");
        console.log("  ", existing, "(stays in the append-only ledger: script/deployments)");
        _dropDeployment(chainId, deploymentName); // drop the stale entry so record() registers the replacement
    }

    /// @notice Resolves a ROLE (`token`/`tokenPool`/`lockBox`/`poolHooks`) to the currently-active
    /// address from `addresses/<chainId>.json`: `.active.<role>` first, then a legacy fallback to a
    /// flat top-level `.<role>` (pre-v2 runtime files). `address(0)` when the file or the key is
    /// absent (never reverts — callers treat the registry as an optional fallback).
    function read(uint256 chainId, string memory role) internal view returns (address) {
        string memory path = _path(chainId);
        if (!VM.exists(path)) return address(0);
        // TOCTOU-safe: a parallel test suite can remove this file between `exists` above and the read
        // below (the resolution tests write then delete a throwaway chain's registry while another
        // suite is constructing HelperConfig, which eagerly reads every configured chain). `readFile`
        // reverts on a missing file, so a raw read would crash that unrelated suite; catch it and treat
        // a vanished file exactly like an absent one (address(0)).
        string memory json;
        try VM.readFile(path) returns (string memory data) {
            json = data;
        } catch {
            return address(0);
        }
        // Resilience: a parallel test suite may be mid-write to this chain's file (VM.writeFile
        // truncates then writes, so a concurrent reader can momentarily see an empty/partial file).
        // The registry is an OPTIONAL fallback that must NEVER revert (see the natspec / HelperConfig),
        // so an empty or unparseable snapshot resolves to address(0) rather than crashing an unrelated
        // test that merely constructed HelperConfig.
        if (bytes(json).length == 0) return address(0);
        string memory activeKey = string.concat(".active.", role);
        try VM.keyExistsJson(json, activeKey) returns (bool exists) {
            if (exists) return VM.parseJsonAddress(json, activeKey);
        } catch {
            return address(0);
        }
        // Legacy fallback: a pre-v2 flat `{ "<role>": "0x.." }` file keeps resolving.
        string memory legacyKey = string.concat(".", role);
        if (VM.keyExistsJson(json, legacyKey)) return VM.parseJsonAddress(json, legacyKey);
        return address(0);
    }

    /// @notice Resolves a uniquely-named `deployments` entry (e.g. a specific pool type + version).
    /// `address(0)` when the file or the key is absent (never reverts).
    function readDeployment(uint256 chainId, string memory deploymentName) internal view returns (address) {
        string memory path = _path(chainId);
        if (!VM.exists(path)) return address(0);
        // TOCTOU-safe (see `read`): tolerate the file being removed by a parallel suite between the
        // `exists` check and the read — a vanished file resolves to address(0), never a revert.
        string memory json;
        try VM.readFile(path) returns (string memory data) {
            json = data;
        } catch {
            return address(0);
        }
        if (bytes(json).length == 0) return address(0); // concurrent-write snapshot: never revert
        // Bracket notation: version keys (e.g. `..._2.0.0`) contain dots, which dot-path notation would
        // mis-split. `["<key>"]` treats the whole name as one literal key.
        string memory key = string.concat(".deployments[\"", deploymentName, "\"]");
        try VM.keyExistsJson(json, key) returns (bool exists) {
            if (exists) return VM.parseJsonAddress(json, key);
        } catch {
            return address(0);
        }
        return address(0);
    }

    /// @notice Upserts the `active[role]` pointer, preserving every other entry (both stores).
    function setActive(uint256 chainId, string memory role, address addr) internal {
        _warnRepoint(chainId, role, addr);
        (string[] memory aKeys, address[] memory aVals, string[] memory dKeys, address[] memory dVals) =
            _loadMaps(chainId);
        (aKeys, aVals) = _upsert(aKeys, aVals, role, addr);
        _store(chainId, aKeys, aVals, dKeys, dVals);
        console.log(string.concat("Registry updated: addresses/", VM.toString(chainId), ".json (active.", role, ")"));
    }

    /// @notice Deterministic view helper: would calling `setActive`/`recordDeterministic` with
    /// (`chainId`, `role`, `addr`) REPOINT the zero-export `active[role]` pointer onto a DIFFERENT
    /// address? Returns (`repoints`, `previous`) where `previous` is the current `active[role]`
    /// (`address(0)` when unset) and `repoints` is true ONLY when a non-zero pointer already exists
    /// and differs from `addr`. First set (previous == 0) and idempotent re-set (previous == addr)
    /// are NOT repoints. Pure of side effects (view) so `setActive`/`recordDeterministic` can gate the
    /// repoint warning on it and the unit tests can assert it directly.
    function wouldRepointActive(uint256 chainId, string memory role, address addr)
        internal
        view
        returns (bool repoints, address previous)
    {
        previous = read(chainId, role);
        repoints = previous != address(0) && previous != addr;
    }

    /// @dev Warn LOUDLY (console only, no behavior change) when an `active[role]` pointer is about to
    /// be silently repointed onto a different address — e.g. deploying a second token on a chain moves
    /// `active.token` off the first fixture, hijacking the zero-export pointer every no-override script
    /// resolves. The repoint still happens; the operator is told how to pin the previous address. Never
    /// fires on a first set or an idempotent re-set (see `wouldRepointActive`). Both write paths that
    /// touch `active[role]` (`setActive` and `recordDeterministic`) route through here.
    function _warnRepoint(uint256 chainId, string memory role, address addr) private view {
        (bool repoints, address previous) = wouldRepointActive(chainId, role, addr);
        if (!repoints) return;
        string memory env = _roleEnvVar(role);
        console.log(
            string.concat(
                "WARNING: active.",
                role,
                " repointed ",
                VM.toString(previous),
                " -> ",
                VM.toString(addr),
                " on chain ",
                VM.toString(chainId),
                "."
            )
        );
        console.log(string.concat("         Scripts with no env override will now resolve ", VM.toString(addr), "."));
        console.log(
            string.concat(
                "         Export ",
                env,
                "=",
                VM.toString(previous),
                " (or <CHAIN>_",
                env,
                "=",
                VM.toString(previous),
                ") to keep targeting the previous one."
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

    /// @notice Upserts a named `deployments[deploymentName]` entry, preserving every other entry.
    function setDeployment(uint256 chainId, string memory deploymentName, address addr) internal {
        (string[] memory aKeys, address[] memory aVals, string[] memory dKeys, address[] memory dVals) =
            _loadMaps(chainId);
        (dKeys, dVals) = _upsert(dKeys, dVals, deploymentName, addr);
        _store(chainId, aKeys, aVals, dKeys, dVals);
        console.log(
            string.concat(
                "Registry updated: addresses/", VM.toString(chainId), ".json (deployments.", deploymentName, ")"
            )
        );
    }

    /// @notice Back-compat alias: records a ROLE pointer (writes `active[role]`). Retained so callers
    /// that only need the resolvable-pointer semantics (and the resolution tests) keep working.
    function set(uint256 chainId, string memory role, address addr) internal {
        setActive(chainId, role, addr);
    }

    /// @notice Deterministic single-writer core: upserts `deployments[deploymentName]` AND
    /// `active[role]` in ONE file write, so the two stores can never drift apart. This is the
    /// anti-duplication write the deploy scripts route every artifact through (via `record`).
    function recordDeterministic(uint256 chainId, string memory role, string memory deploymentName, address addr)
        internal
    {
        _warnRepoint(chainId, role, addr);
        (string[] memory aKeys, address[] memory aVals, string[] memory dKeys, address[] memory dVals) =
            _loadMaps(chainId);
        (dKeys, dVals) = _upsert(dKeys, dVals, deploymentName, addr);
        (aKeys, aVals) = _upsert(aKeys, aVals, role, addr);
        _store(chainId, aKeys, aVals, dKeys, dVals);
        console.log(
            string.concat(
                "Registry updated: addresses/",
                VM.toString(chainId),
                ".json (deployments.",
                deploymentName,
                " + active.",
                role,
                ")"
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal file (de)serialization
    // ─────────────────────────────────────────────────────────────────────────

    function _path(uint256 chainId) private view returns (string memory) {
        return string.concat(VM.projectRoot(), "/addresses/", VM.toString(chainId), ".json");
    }

    /// @dev Drops `deploymentName` from `deployments` and clears any `active[role]` that pointed at the
    /// dropped address (so a forced redeploy leaves no dangling active pointer).
    function _dropDeployment(uint256 chainId, string memory deploymentName) private {
        (string[] memory aKeys, address[] memory aVals, string[] memory dKeys, address[] memory dVals) =
            _loadMaps(chainId);

        address dropped = address(0);
        for (uint256 i = 0; i < dKeys.length; i++) {
            if (keccak256(bytes(dKeys[i])) == keccak256(bytes(deploymentName))) {
                dropped = dVals[i];
                break;
            }
        }
        (dKeys, dVals) = _remove(dKeys, dVals, deploymentName);
        if (dropped != address(0)) {
            (aKeys, aVals) = _removeByValue(aKeys, aVals, dropped);
        }
        _store(chainId, aKeys, aVals, dKeys, dVals);
    }

    function _loadMaps(uint256 chainId)
        private
        view
        returns (string[] memory aKeys, address[] memory aVals, string[] memory dKeys, address[] memory dVals)
    {
        string memory path = _path(chainId);
        if (!VM.exists(path)) {
            return (new string[](0), new address[](0), new string[](0), new address[](0));
        }
        string memory json = VM.readFile(path);
        (aKeys, aVals) = _readObj(json, ".active");
        (dKeys, dVals) = _readObj(json, ".deployments");
    }

    function _readObj(string memory json, string memory objPath)
        private
        view
        returns (string[] memory keys, address[] memory vals)
    {
        if (!VM.keyExistsJson(json, objPath)) {
            return (new string[](0), new address[](0));
        }
        keys = VM.parseJsonKeys(json, objPath);
        vals = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            // Bracket notation so keys containing dots (versioned pool names) are read as one literal key.
            vals[i] = VM.parseJsonAddress(json, string.concat(objPath, "[\"", keys[i], "\"]"));
        }
    }

    function _store(
        uint256 chainId,
        string[] memory aKeys,
        address[] memory aVals,
        string[] memory dKeys,
        address[] memory dVals
    ) private {
        string memory body = string.concat(
            "{\n    \"active\": ", _obj(aKeys, aVals), ",\n    \"deployments\": ", _obj(dKeys, dVals), "\n}\n"
        );
        VM.writeFile(_path(chainId), body);
    }

    /// @dev Serializes a `{key: address}` map with 2-space nesting under a 4-space-indented parent key.
    function _obj(string[] memory keys, address[] memory vals) private pure returns (string memory) {
        if (keys.length == 0) return "{}";
        string memory inner = "";
        for (uint256 i = 0; i < keys.length; i++) {
            inner = string.concat(
                inner, "\n        \"", keys[i], "\": \"", VM.toString(vals[i]), "\"", i + 1 < keys.length ? "," : ""
            );
        }
        return string.concat("{", inner, "\n    }");
    }

    function _upsert(string[] memory keys, address[] memory vals, string memory key, address val)
        private
        pure
        returns (string[] memory, address[] memory)
    {
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) {
                vals[i] = val;
                return (keys, vals);
            }
        }
        string[] memory nk = new string[](keys.length + 1);
        address[] memory nv = new address[](keys.length + 1);
        for (uint256 i = 0; i < keys.length; i++) {
            nk[i] = keys[i];
            nv[i] = vals[i];
        }
        nk[keys.length] = key;
        nv[keys.length] = val;
        return (nk, nv);
    }

    function _remove(string[] memory keys, address[] memory vals, string memory key)
        private
        pure
        returns (string[] memory, address[] memory)
    {
        uint256 n = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) != keccak256(bytes(key))) n++;
        }
        string[] memory nk = new string[](n);
        address[] memory nv = new address[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) continue;
            nk[j] = keys[i];
            nv[j] = vals[i];
            j++;
        }
        return (nk, nv);
    }

    function _removeByValue(string[] memory keys, address[] memory vals, address val)
        private
        pure
        returns (string[] memory, address[] memory)
    {
        uint256 n = 0;
        for (uint256 i = 0; i < vals.length; i++) {
            if (vals[i] != val) n++;
        }
        string[] memory nk = new string[](n);
        address[] memory nv = new address[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (vals[i] == val) continue;
            nk[j] = keys[i];
            nv[j] = vals[i];
            j++;
        }
        return (nk, nv);
    }
}
