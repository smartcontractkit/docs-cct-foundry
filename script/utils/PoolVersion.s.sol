// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";

/// @dev The v2 rate-limit getter, present from pool version 2.0.0. Used by the override cross-check
///      and the unknown-version read fallback; never used to infer a version.
interface IRateLimitGetterV2 {
    function getCurrentRateLimiterState(uint64 remoteChainSelector, bool fastFinality)
        external
        view
        returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound);
}

/// @dev The v1 rate-limit getter, present on pool versions 1.5.0 through 1.6.1.
interface IRateLimitGetterV1 {
    function getCurrentOutboundRateLimiterState(uint64 remoteChainSelector)
        external
        view
        returns (RateLimiter.TokenBucket memory);
}

/// @dev The singular remote-pool getter, the only remote-pool read on pool version 1.5.0.
interface IRemotePoolReaderV150 {
    function getRemotePool(uint64 remoteChainSelector) external view returns (bytes memory);
}

/// @dev The plural remote-pool getter, present from pool version 1.5.1.
interface IRemotePoolReader {
    function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory);
}

/// @title PoolVersion
/// @notice The impure resolver: reads a pool's on-chain `typeAndVersion()` and resolves it to the
///         `PoolVersions.Version` catalog. Mutating scripts call `resolve` (refuses anything the
///         catalog does not know, with a named error per failure class); read-only scripts call
///         `tryResolve` (never reverts on an unrecognized pool; degrades to `UNKNOWN` so the caller
///         can warn and continue best effort).
/// @dev The version token is only comparable within the standard TokenPool lineage, so the type
///      prefix is allowlisted: a specialized pool (e.g. `USDCTokenPool`) carries an independent
///      version namespace and is refused for dispatch. The address-scoped `POOL_VERSION_OVERRIDE`
///      env var (`<pool>=<catalogedVersion>`, comma-separated entries) maps one pool to a cataloged
///      version for one invocation; every use is logged loudly and cross-checked against the pool's
///      actual rate-limit getter surface before it is honored. See docs/pool-versions.md.
library PoolVersion {
    // Access the forge-std vm cheatcode from within a library.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant OVERRIDE_ENV = "POOL_VERSION_OVERRIDE";

    // ─────────────────────────────────────────────────────────────────────────
    // Resolution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Resolves the pool's contract version for a MUTATING path. Reverts with a named error
    ///         when the contract has no `typeAndVersion()`, reports a foreign type prefix, reports a
    ///         `-dev` build, or reports a version the catalog does not know. Returns the resolved
    ///         version and the full on-chain `typeAndVersion()` string (always the TRUE on-chain
    ///         string, also when an override supplied the version).
    function resolve(address pool) internal view returns (PoolVersions.Version version, string memory full) {
        return resolveWith(pool, vm.envOr(OVERRIDE_ENV, string("")));
    }

    /// @notice `resolve` with the override specification passed explicitly (the env-reading `resolve`
    ///         delegates here; tests inject override strings without mutating the process env).
    function resolveWith(address pool, string memory overrideSpec)
        internal
        view
        returns (PoolVersions.Version version, string memory full)
    {
        full = _readTypeAndVersion(pool);
        (string memory typePrefix, string memory token) = _splitTypeAndVersion(full);

        (bool overridden, PoolVersions.Version overrideVersion) = _overrideFor(pool, overrideSpec);
        if (overridden) {
            _warnOverride(pool, full, overrideVersion);
            _crossCheckOverride(pool, full, overrideVersion);
            return (overrideVersion, full);
        }

        _requireKnownTypePrefix(pool, full, typePrefix);
        _requireNoDevBuild(pool, full, token);

        version = PoolVersions.fromVersionToken(token);
        if (version == PoolVersions.Version.UNKNOWN) {
            revert(
                string.concat(
                    "UnsupportedPoolVersion: pool ",
                    vm.toString(pool),
                    " reports \"",
                    full,
                    "\". This repo dispatches on the pool contract version and has not been validated against \"",
                    token,
                    "\". Supported versions: ",
                    PoolVersions.SUPPORTED_VERSIONS,
                    ". Note: npm package versions are not pool versions (npm 1.6.0 ships pools stamped 1.5.1). ",
                    "If you have verified this pool's ABI matches a cataloged version, set ",
                    OVERRIDE_ENV,
                    "=",
                    vm.toString(pool),
                    "=<catalogedVersion>. See ",
                    PoolVersions.DOCS,
                    "#unknown-versions; the catalog lives in ",
                    PoolVersions.CATALOG,
                    "."
                )
            );
        }
    }

    /// @notice Resolves the pool's contract version for a READ-ONLY path. Never reverts on an
    ///         unrecognized pool: returns `ok = false` and `UNKNOWN` (with the raw on-chain string
    ///         when one exists) so the caller can warn and continue best effort. A valid
    ///         `POOL_VERSION_OVERRIDE` entry for the pool is honored here too (same warning and
    ///         cross-check); a malformed override entry still reverts, on every path.
    function tryResolve(address pool)
        internal
        view
        returns (bool ok, PoolVersions.Version version, string memory full)
    {
        return tryResolveWith(pool, vm.envOr(OVERRIDE_ENV, string("")));
    }

    /// @notice `tryResolve` with the override specification passed explicitly.
    function tryResolveWith(address pool, string memory overrideSpec)
        internal
        view
        returns (bool ok, PoolVersions.Version version, string memory full)
    {
        if (pool.code.length == 0) return (false, PoolVersions.Version.UNKNOWN, "");
        try ITypeAndVersion(pool).typeAndVersion() returns (string memory t) {
            full = t;
        } catch {
            return (false, PoolVersions.Version.UNKNOWN, "");
        }

        (string memory typePrefix, string memory token) = _splitTypeAndVersion(full);

        (bool overridden, PoolVersions.Version overrideVersion) = _overrideFor(pool, overrideSpec);
        if (overridden) {
            _warnOverride(pool, full, overrideVersion);
            _crossCheckOverride(pool, full, overrideVersion);
            return (true, overrideVersion, full);
        }

        if (!_isKnownTypePrefix(typePrefix)) return (false, PoolVersions.Version.UNKNOWN, full);
        version = PoolVersions.fromVersionToken(token);
        if (version == PoolVersions.Version.UNKNOWN) return (false, PoolVersions.Version.UNKNOWN, full);
        return (true, version, full);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LockRelease v1.x liquidity fence (two-dimensional: type AND version)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The type prefix that carries the v1.x rebalancer/liquidity surface. BurnMint pools have no
    ///      liquidity to manage, and specialized pools version independently, so the fence is scoped to
    ///      the standard LockRelease lineage.
    string internal constant LOCK_RELEASE_TYPE = "LockReleaseTokenPool";

    /// @notice Fences a MUTATING v1.x LockRelease liquidity operation on both axes and returns the
    ///         resolved version (< 2.0.0) so the caller can build the write. The check is two-dimensional:
    ///         1. TYPE — the pool's `typeAndVersion()` must start with `LockReleaseTokenPool`. A BurnMint
    ///            (or any other) pool has no pool-held liquidity, so it is refused by name with the
    ///            reported type, never routed to the generic unsupported-operation error.
    ///         2. VERSION — a 2.0.0 (or later) LockRelease pool no longer holds liquidity (the external
    ///            lock box replaced the rebalancer model), so it is refused with a HELPFUL pointer at the
    ///            lock box scripts rather than the generic unsupported-operation error.
    ///         Only after both pass does it assert the capability range (`PROVIDE_LIQUIDITY`, which shares
    ///         the v1.x range with the other liquidity ops). Uncataloged / `-dev` / non-pool addresses are
    ///         refused earlier by `resolve` (this broadcasts, so it uses the strict resolver).
    function requireLockReleaseLiquidity(address pool)
        internal
        view
        returns (PoolVersions.Version version, string memory full)
    {
        (version, full) = resolve(pool);
        (string memory typePrefix,) = _splitTypeAndVersion(full);

        if (keccak256(bytes(typePrefix)) != keccak256(bytes(LOCK_RELEASE_TYPE))) {
            revert(
                string.concat(
                    "UnsupportedPoolTypeForLiquidity: liquidity management is only on LockRelease pools; this is a ",
                    typePrefix,
                    " (pool ",
                    vm.toString(pool),
                    ", on-chain \"",
                    full,
                    "\"). See ",
                    PoolVersions.DOCS,
                    "#pool-types."
                )
            );
        }

        if (version >= PoolVersions.Version.V2_0_0) {
            revert(
                string.concat(
                    "LiquidityManagedByLockBox: on 2.0.0 LockRelease pools, liquidity is managed via the external lock box",
                    " - use operations/DepositToLockBox.s.sol / WithdrawFromLockBox.s.sol (pool ",
                    vm.toString(pool),
                    ", on-chain \"",
                    full,
                    "\")."
                )
            );
        }

        PoolVersions.requireSupports(PoolVersions.Op.PROVIDE_LIQUIDITY, version, pool);
    }

    /// @notice The type prefix of a raw `typeAndVersion()` string (everything before the last space), for
    ///         read-path scripts that branch on the pool type without a mutating fence. An empty string in
    ///         (a non-pool) yields an empty prefix.
    function typePrefixOf(string memory full) internal pure returns (string memory typePrefix) {
        (typePrefix,) = _splitTypeAndVersion(full);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Version-dispatched reads
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The remote pool addresses configured for `remoteChainSelector`, dispatched per
    ///         version: the singular `getRemotePool` on 1.5.0 (wrapped into a one-element array),
    ///         the plural `getRemotePools` from 1.5.1. On `UNKNOWN` (read paths only) it degrades
    ///         to best effort: plural getter first, singular as fallback.
    function remotePools(address pool, PoolVersions.Version version, uint64 remoteChainSelector)
        internal
        view
        returns (bytes[] memory pools)
    {
        if (version == PoolVersions.Version.V1_5_0) return _singularRemotePool(pool, remoteChainSelector);
        if (version != PoolVersions.Version.UNKNOWN) {
            return IRemotePoolReader(pool).getRemotePools(remoteChainSelector);
        }
        try IRemotePoolReader(pool).getRemotePools(remoteChainSelector) returns (bytes[] memory p) {
            return p;
        } catch {
            return _singularRemotePool(pool, remoteChainSelector);
        }
    }

    function _singularRemotePool(address pool, uint64 remoteChainSelector) private view returns (bytes[] memory pools) {
        pools = new bytes[](1);
        pools[0] = IRemotePoolReaderV150(pool).getRemotePool(remoteChainSelector);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // typeAndVersion reading and parsing
    // ─────────────────────────────────────────────────────────────────────────

    function _readTypeAndVersion(address pool) private view returns (string memory full) {
        // The code check must come first: a call to a codeless address succeeds with empty return
        // data, and the decode failure that follows is not catchable by the try below.
        if (pool.code.length > 0) {
            try ITypeAndVersion(pool).typeAndVersion() returns (string memory t) {
                return t;
            } catch {
                revert(_notAPool(pool));
            }
        }
        revert(_notAPool(pool));
    }

    function _notAPool(address pool) private pure returns (string memory) {
        return string.concat(
            "NotACcipTokenPool: no typeAndVersion() at ",
            vm.toString(pool),
            "; not a CCIP token pool. Did you pass the token address instead of the pool? See ",
            PoolVersions.DOCS,
            "."
        );
    }

    /// @dev Splits `typeAndVersion` at the LAST space into (type prefix, version token), after
    ///      trimming trailing whitespace. No space yields an empty prefix and the whole string as
    ///      the token.
    function _splitTypeAndVersion(string memory s)
        private
        pure
        returns (string memory typePrefix, string memory token)
    {
        bytes memory b = bytes(s);
        uint256 end = b.length;
        while (end > 0 && b[end - 1] == 0x20) {
            end--;
        }
        uint256 lastSpace = type(uint256).max;
        for (uint256 i = 0; i < end; i++) {
            if (b[i] == 0x20) lastSpace = i;
        }
        if (lastSpace == type(uint256).max) return ("", _slice(b, 0, end));
        return (_slice(b, 0, lastSpace), _slice(b, lastSpace + 1, end));
    }

    function _slice(bytes memory b, uint256 start, uint256 end) private pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /// @dev The standard TokenPool lineage whose version tokens are comparable in the catalog.
    ///      Specialized pools (USDCTokenPool, siloed or hybrid variants, forks with renamed types)
    ///      version independently and must not dispatch as TokenPool versions.
    function _isKnownTypePrefix(string memory typePrefix) private pure returns (bool) {
        bytes32 h = keccak256(bytes(typePrefix));
        return h == keccak256(bytes("BurnMintTokenPool")) || h == keccak256(bytes("BurnFromMintTokenPool"))
            || h == keccak256(bytes("BurnWithFromMintTokenPool")) || h == keccak256(bytes("LockReleaseTokenPool"));
    }

    function _requireKnownTypePrefix(address pool, string memory full, string memory typePrefix) private pure {
        if (_isKnownTypePrefix(typePrefix)) return;
        revert(
            string.concat(
                "UnsupportedPoolType: pool ",
                vm.toString(pool),
                " reports \"",
                full,
                "\". Version tokens are only comparable within the standard TokenPool lineage ",
                "(BurnMintTokenPool, BurnFromMintTokenPool, BurnWithFromMintTokenPool, LockReleaseTokenPool); \"",
                typePrefix,
                "\" versions independently, so its version token must not dispatch as a TokenPool version. ",
                "If you have verified this pool's ABI matches a cataloged version, set ",
                OVERRIDE_ENV,
                "=",
                vm.toString(pool),
                "=<catalogedVersion>. See ",
                PoolVersions.DOCS,
                "#pool-types."
            )
        );
    }

    function _requireNoDevBuild(address pool, string memory full, string memory token) private pure {
        if (!_contains(token, "-dev")) return;
        revert(
            string.concat(
                "DevBuildRefused: pool ",
                vm.toString(pool),
                " reports \"",
                full,
                "\", an unaudited development build with no stable ABI. Refusing to dispatch. ",
                "If you accept the risk and have verified the ABI against a cataloged version, set ",
                OVERRIDE_ENV,
                "=",
                vm.toString(pool),
                "=<catalogedVersion> (one of ",
                PoolVersions.SUPPORTED_VERSIONS,
                "). See ",
                PoolVersions.DOCS,
                "#dev-builds."
            )
        );
    }

    function _contains(string memory s, string memory needle) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // POOL_VERSION_OVERRIDE (address-scoped escape hatch)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Parses the override specification (`<addr>=<catalogedVersion>`, comma-separated) and
    ///      returns the entry for `pool` when one exists. EVERY entry is validated on every parse:
    ///      a malformed entry anywhere aborts, on read and write paths alike, so a typo cannot sit
    ///      silently in the environment.
    function _overrideFor(address pool, string memory overrideSpec)
        private
        pure
        returns (bool found, PoolVersions.Version version)
    {
        if (bytes(overrideSpec).length == 0) return (false, PoolVersions.Version.UNKNOWN);
        string[] memory entries = vm.split(overrideSpec, ",");
        for (uint256 i = 0; i < entries.length; i++) {
            string[] memory pair = vm.split(entries[i], "=");
            if (pair.length != 2 || !_isHexAddress(pair[0])) revert(_malformedOverride(entries[i]));
            PoolVersions.Version v = PoolVersions.fromVersionToken(pair[1]);
            if (v == PoolVersions.Version.UNKNOWN) revert(_malformedOverride(entries[i]));
            if (!found && vm.parseAddress(pair[0]) == pool) {
                found = true;
                version = v;
            }
        }
    }

    function _malformedOverride(string memory entry) private pure returns (string memory) {
        return string.concat(
            "PoolVersionOverrideMalformed: entry \"",
            entry,
            "\" in ",
            OVERRIDE_ENV,
            " is not <address>=<catalogedVersion>. The version must be one of ",
            PoolVersions.SUPPORTED_VERSIONS,
            ". See ",
            PoolVersions.DOCS,
            "#overrides."
        );
    }

    function _isHexAddress(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length != 42 || b[0] != "0" || (b[1] != "x" && b[1] != "X")) return false;
        for (uint256 i = 2; i < 42; i++) {
            bytes1 c = b[i];
            bool digit = c >= "0" && c <= "9";
            bool lower = c >= "a" && c <= "f";
            bool upper = c >= "A" && c <= "F";
            if (!digit && !lower && !upper) return false;
        }
        return true;
    }

    function _warnOverride(address pool, string memory full, PoolVersions.Version version) private pure {
        console.log("");
        console.log("==================== POOL VERSION OVERRIDE ====================");
        console.log(
            string.concat(
                unicode"⚠️  ",
                OVERRIDE_ENV,
                " is treating pool ",
                vm.toString(pool),
                " as contract version ",
                PoolVersions.toString(version),
                "."
            )
        );
        console.log(string.concat(unicode"⚠️  On-chain typeAndVersion(): \"", full, "\""));
        console.log(unicode"⚠️  The catalog has not validated this pool; the ABI assertion is yours.");
        console.log(
            string.concat(
                unicode"⚠️  The override applies to this invocation only. See ", PoolVersions.DOCS, "#overrides."
            )
        );
        console.log("===============================================================");
        console.log("");
    }

    /// @dev The override is an ABI assertion, so assert it: an override claiming 2.0.0 or later
    ///      must answer the v2 rate-limit getter; an override claiming an earlier version must
    ///      answer the v1 getter. A disagreement aborts with a diagnostic naming both facts.
    function _crossCheckOverride(address pool, string memory full, PoolVersions.Version version) private view {
        if (version >= PoolVersions.Version.V2_0_0) {
            try IRateLimitGetterV2(pool).getCurrentRateLimiterState(0, false) returns (
                RateLimiter.TokenBucket memory, RateLimiter.TokenBucket memory
            ) {
                return;
            } catch {
                revert(
                    string.concat(
                        "PoolVersionOverrideMismatch: ",
                        OVERRIDE_ENV,
                        " claims pool ",
                        vm.toString(pool),
                        " (on-chain \"",
                        full,
                        "\") is version ",
                        PoolVersions.toString(version),
                        ", but the v2 getter getCurrentRateLimiterState(uint64,bool) does not answer on it. ",
                        "The override looks wrong; fix or remove it. See ",
                        PoolVersions.DOCS,
                        "#overrides."
                    )
                );
            }
        }
        try IRateLimitGetterV1(pool).getCurrentOutboundRateLimiterState(0) returns (RateLimiter.TokenBucket memory) {
            return;
        } catch {
            revert(
                string.concat(
                    "PoolVersionOverrideMismatch: ",
                    OVERRIDE_ENV,
                    " claims pool ",
                    vm.toString(pool),
                    " (on-chain \"",
                    full,
                    "\") is version ",
                    PoolVersions.toString(version),
                    ", but the v1 getter getCurrentOutboundRateLimiterState(uint64) does not answer on it. ",
                    "The override looks wrong; fix or remove it. See ",
                    PoolVersions.DOCS,
                    "#overrides."
                )
            );
        }
    }
}
