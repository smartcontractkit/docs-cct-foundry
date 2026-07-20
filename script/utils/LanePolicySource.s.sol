// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @notice Shared plumbing for scripts that resolve their inputs through the env-over-lanes{}
///         input ladder: local-chain-config discovery, lanes{} entry matching, declared-bucket
///         parsing, and the env-access seams the ladder tests inject through.
///
/// The helpers are deliberately DUPLICATED from `ApplyChainUpdates` (the reference ladder
/// implementation, `script/setup/ApplyChainUpdates.s.sol`) rather than shared with it:
/// ApplyChainUpdates keeps its own private copies so its behavior and test suite stay
/// byte-stable. Any semantic change here must be mirrored there (and vice versa).
abstract contract LanePolicySource is Script {
    // ─────────────────────────────────────────────────────────────────────────
    // Env-access seams
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Env-access seams for the input-resolution ladder. Virtual so tests can inject values
    ///      without vm.setEnv (env vars are process-global and forge runs suites in parallel);
    ///      the default implementations preserve the original vm.envOr reads exactly.
    function _envExists(string memory name) internal view virtual returns (bool) {
        string memory sentinel = "__not_set__";
        return keccak256(bytes(vm.envOr(name, sentinel))) != keccak256(bytes(sentinel));
    }

    function _envUint(string memory name) internal view virtual returns (uint256) {
        return vm.envOr(name, uint256(0));
    }

    function _envBool(string memory name, bool defaultValue) internal view virtual returns (bool) {
        return vm.envOr(name, defaultValue);
    }

    /// @dev Raw string value of an env var (empty when unset). Consumers that parse a list (e.g. a
    ///      comma-separated address list) read the raw value through this seam so tests can inject it
    ///      without vm.setEnv of a process-global name.
    function _envString(string memory name) internal view virtual returns (string memory) {
        return vm.envOr(name, string(""));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Local config discovery + lanes{} matching
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The local chain's project store (`project/<name>.json`), which now holds the `lanes{}`
    ///      subtree the ladder resolves - the empty JSON object `"{}"` when the chain has no project file
    ///      yet. The `"{}"` sentinel (NOT `""`) is deliberate: `keyExistsJson("", …)` REVERTS ("EOF while
    ///      parsing"), whereas `keyExistsJson("{}", …)` returns false, so callers read an absent store as
    ///      "no lane declared" without a raw parse revert. Chain FACTS still come from
    ///      `_findLocalChainConfig`; lane POLICY comes from here.
    function _localProjectJson(string memory name) internal view returns (string memory) {
        string memory p = ProjectStore._path(name);
        if (!vm.exists(p)) return "{}";
        string memory data = vm.readFile(p);
        return bytes(data).length == 0 ? "{}" : data;
    }

    /// @dev The local chain's config file (matched on the declared `chainId` == block.chainid),
    ///      discovered the same way HelperConfig discovers chains: by scanning `config/chains/`.
    function _findLocalChainConfig() internal view returns (bool found, string memory name, string memory json) {
        string[] memory names = ChainConfig._names();
        for (uint256 i = 0; i < names.length; i++) {
            string memory path = string.concat(vm.projectRoot(), "/config/chains/", names[i], ".json");
            // A file deleted or half-written between the directory scan and the read (parallel
            // test suites clean up scratch configs) is skipped, never an aborted run. Cheatcodes
            // are external calls to the VM contract, so try/catch applies directly - no self-call
            // (forge rejects address(this) in script contracts at runtime).
            try vm.readFile(path) returns (string memory candidate) {
                try vm.parseJsonUint(candidate, ".chainId") returns (uint256 declaredChainId) {
                    if (declaredChainId == block.chainid) return (true, names[i], candidate);
                } catch {
                    continue;
                }
            } catch {
                continue;
            }
        }
        return (false, "", "");
    }

    /// @dev Finds the lanes{} entry key for the destination in the local chain config. Match by
    ///      remote chain name first - a lanes key IS the remote's config file basename, and
    ///      DEST_CHAIN may carry either that basename or the remote's chainNameIdentifier - then
    ///      fall back to remoteSelector equality (the same join key the doctor's lanes rung
    ///      reconciles on).
    function _findLaneKey(string memory json, string memory destChainName, uint64 destChainSelector)
        internal
        view
        returns (bool found, string memory key)
    {
        if (!vm.keyExistsJson(json, ".lanes")) return (false, "");
        string[] memory keys = vm.parseJsonKeys(json, ".lanes");

        for (uint256 i = 0; i < keys.length; i++) {
            if (_sameString(keys[i], destChainName)) return (true, keys[i]);
        }
        for (uint256 i = 0; i < keys.length; i++) {
            (bool ok, ChainConfig.Chain memory c,) = ChainConfig._tryLoad(keys[i]);
            if (ok && _sameString(c.chainNameIdentifier, destChainName)) return (true, keys[i]);
        }
        for (uint256 i = 0; i < keys.length; i++) {
            string memory selectorKey = string.concat(".lanes.", keys[i], ".remoteSelector");
            if (vm.keyExistsJson(json, selectorKey) && vm.parseJsonUint(json, selectorKey) == destChainSelector) {
                return (true, keys[i]);
            }
        }
        return (false, "");
    }

    /// @dev The destination's config file basename for remediation hints: the DEST_CHAIN value
    ///      itself when a config file of that name exists, otherwise the file whose
    ///      chainNameIdentifier matches; falls back to the raw DEST_CHAIN value when the remote
    ///      has no config file yet.
    function _remoteConfigName(string memory destChainName) internal view returns (string memory) {
        string[] memory names = ChainConfig._names();
        for (uint256 i = 0; i < names.length; i++) {
            if (_sameString(names[i], destChainName)) return names[i];
        }
        for (uint256 i = 0; i < names.length; i++) {
            (bool ok, ChainConfig.Chain memory c,) = ChainConfig._tryLoad(names[i]);
            if (ok && _sameString(c.chainNameIdentifier, destChainName)) return names[i];
        }
        return destChainName;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Declared-policy parsing (the doctor's conventions, parsed identically)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Declared (capacity, rate) at `declPath`; a missing key reads as 0. Same conventions as
    ///      the doctor's lanes rung (`VerifyChain._declaredBucket`) so all consumers parse
    ///      identically: quoted-decimal uints via `vm.parseJsonUint`, absent key == 0.
    function _declaredBucket(string memory json, string memory declPath)
        internal
        view
        returns (uint256 capacity, uint256 rate)
    {
        string memory capacityKey = string.concat(declPath, ".capacity");
        string memory rateKey = string.concat(declPath, ".rate");
        capacity = vm.keyExistsJson(json, capacityKey) ? vm.parseJsonUint(json, capacityKey) : 0;
        rate = vm.keyExistsJson(json, rateKey) ? vm.parseJsonUint(json, rateKey) : 0;
    }

    /// @dev A declared bucket as a RateLimiter.Config: enabled iff capacity or rate is non-zero -
    ///      the same inference the doctor's lanes rung uses (declared 0/0 is declared-disabled).
    function _declaredConfig(uint256 capacity, uint256 rate) internal pure returns (RateLimiter.Config memory) {
        bool enabled = capacity != 0 || rate != 0;
        return RateLimiter.Config({isEnabled: enabled, capacity: uint128(capacity), rate: uint128(rate)});
    }

    /// @dev Same agreement rule as the doctor's lanes rung (`VerifyChain._reconcileBucket`):
    ///      enabled states must match, and an enabled bucket must match on capacity and rate.
    function _bucketDiverges(RateLimiter.Config memory applied, uint256 declaredCapacity, uint256 declaredRate)
        internal
        pure
        returns (bool)
    {
        bool declaredEnabled = declaredCapacity != 0 || declaredRate != 0;
        if (applied.isEnabled != declaredEnabled) return true;
        return applied.isEnabled && (applied.capacity != declaredCapacity || applied.rate != declaredRate);
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
