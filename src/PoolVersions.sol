// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts@5.3.0/utils/Strings.sol";

/// @title PoolVersions
/// @notice The pool-version catalog: the ordered set of TokenPool contract versions this repo
///         dispatches on, and the per-operation capability-range table derived from the verified
///         per-version ABI surface.
/// @dev Doctrine. "Which version is this pool" is answered by parsing the pool's own on-chain
///      `typeAndVersion()` into this ordered enum (script-side, `script/utils/PoolVersion.s.sol`),
///      never by npm package versions (the npm 1.6.0 package ships pools stamped 1.5.1) and never
///      by capability probes (a revert does not say WHY it reverted). Every version-shaped behavior,
///      reads and writes alike, dispatches on the enum.
///
///      Capabilities are RANGES, not floors: 2.0.0 removed `setChainRateLimiterConfig`, `setRouter`,
///      `setRateLimitAdmin`, and pool-level `applyAllowListUpdates` while adding the v2 surface, so
///      an open-ended "at least version X" check is wrong for half of the table. Each operation
///      declares `[introducedIn, removedIn)` in ONE place (`opRange` below); call sites gate through
///      `requireSupports` and never compare versions inline.
///
///      Unknown versions: read-only paths degrade to best effort with a warning; mutating paths
///      refuse with a named error. The address-scoped `POOL_VERSION_OVERRIDE` escape hatch maps one
///      pool to a cataloged version for one invocation, is logged loudly, and is cross-checked
///      against the pool's actual getter surface before it is honored.
///
///      NOT covered by this doctrine: the deploy-time `typeAndVersion` equality assertion (a
///      pinned-dependency guard, exact string on purpose) and the address-registry keying (a
///      provenance record of the full on-chain string, on purpose). Both stay as they are.
///
///      Adding a version: insert the enum member in order, fill its cell in EVERY `opRange` entry,
///      extend `fromVersionToken`, and update `docs/pool-versions.md`. The table-driven test in
///      `test/actions/PoolVersionDispatch.t.sol` asserts every (operation, version) cell, so a
///      missing column fails the suite. Never persist or log the enum ordinal; persist the full
///      `typeAndVersion()` string.
library PoolVersions {
    /// @notice Ordered catalog of dispatchable pool contract versions. `UNKNOWN` is the zero-value
    ///         sentinel so a default-initialized value can never dispatch as 1.5.0.
    enum Version {
        UNKNOWN,
        V1_5_0,
        V1_5_1,
        V1_6_1,
        V2_0_0
    }

    /// @notice Every version-dispatched operation. One row per entry in the capability-range table.
    enum Op {
        APPLY_CHAIN_UPDATES, // modern (removes[], adds[]) shape, selector 0xe8a1da17
        APPLY_CHAIN_UPDATES_V150, // 1.5.0 single-argument shape, selector 0xdb6327dc
        ADD_REMOTE_POOL,
        REMOVE_REMOTE_POOL,
        GET_REMOTE_POOLS, // plural read, bytes[] per chain
        GET_REMOTE_POOL, // singular read, the only 1.5.0 remote-pool getter
        SET_CHAIN_RATE_LIMITER_CONFIG, // v1 rate-limit setter, removed in 2.0.0
        SET_RATE_LIMIT_CONFIG, // v2 rate-limit setter
        SET_ROUTER, // removed in 2.0.0 (router moved into dynamic config)
        SET_RATE_LIMIT_ADMIN, // removed in 2.0.0 (admin moved into dynamic config)
        SET_DYNAMIC_CONFIG, // v2 replacement for setRouter/setRateLimitAdmin
        APPLY_ALLOW_LIST_UPDATES_POOL, // pool-level allowlist; moved to AdvancedPoolHooks in 2.0.0
        SET_TOKEN_TRANSFER_FEE_CONFIG, // v2-only: applyTokenTransferFeeConfigUpdates
        SET_ALLOWED_FINALITY_CONFIG, // v2-only: setAllowedFinalityConfig
        APPLY_CCV_CONFIG, // v2-only: AdvancedPoolHooks.applyCCVConfigUpdates (per-lane CCV requirements)
        SET_CCV_THRESHOLD, // v2-only: AdvancedPoolHooks.setThresholdAmount (pool-global CCV threshold)
        GET_REBALANCER, // v1.x LockRelease read: getRebalancer; removed in 2.0.0 (lockbox model)
        SET_REBALANCER, // v1.x LockRelease: setRebalancer (onlyOwner); removed in 2.0.0
        PROVIDE_LIQUIDITY, // v1.x LockRelease: provideLiquidity (only rebalancer); removed in 2.0.0
        WITHDRAW_LIQUIDITY // v1.x LockRelease: withdrawLiquidity (only rebalancer); removed in 2.0.0
    }

    string internal constant SUPPORTED_VERSIONS = "1.5.0, 1.5.1, 1.6.1, 2.0.0";
    string internal constant DOCS = "docs/pool-versions.md";
    string internal constant CATALOG = "src/PoolVersions.sol";

    /// @notice The capability range of `op` as `[introducedIn, removedIn)`. `removedIn == UNKNOWN`
    ///         means the operation exists on every cataloged version from `introducedIn` onward.
    ///         Ranges follow the source-verified per-version ABI surface of the TokenPool lineage.
    function opRange(Op op) internal pure returns (Version introducedIn, Version removedIn) {
        if (op == Op.APPLY_CHAIN_UPDATES) return (Version.V1_5_1, Version.UNKNOWN);
        if (op == Op.APPLY_CHAIN_UPDATES_V150) return (Version.V1_5_0, Version.V1_5_1);
        if (op == Op.ADD_REMOTE_POOL) return (Version.V1_5_1, Version.UNKNOWN);
        if (op == Op.REMOVE_REMOTE_POOL) return (Version.V1_5_1, Version.UNKNOWN);
        if (op == Op.GET_REMOTE_POOLS) return (Version.V1_5_1, Version.UNKNOWN);
        if (op == Op.GET_REMOTE_POOL) return (Version.V1_5_0, Version.V1_5_1);
        if (op == Op.SET_CHAIN_RATE_LIMITER_CONFIG) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.SET_RATE_LIMIT_CONFIG) return (Version.V2_0_0, Version.UNKNOWN);
        if (op == Op.SET_ROUTER) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.SET_RATE_LIMIT_ADMIN) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.SET_DYNAMIC_CONFIG) return (Version.V2_0_0, Version.UNKNOWN);
        if (op == Op.APPLY_ALLOW_LIST_UPDATES_POOL) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.SET_TOKEN_TRANSFER_FEE_CONFIG) return (Version.V2_0_0, Version.UNKNOWN);
        if (op == Op.SET_ALLOWED_FINALITY_CONFIG) return (Version.V2_0_0, Version.UNKNOWN);
        if (op == Op.APPLY_CCV_CONFIG) return (Version.V2_0_0, Version.UNKNOWN);
        if (op == Op.SET_CCV_THRESHOLD) return (Version.V2_0_0, Version.UNKNOWN);
        // v1.x LockRelease rebalancer/liquidity surface: present 1.5.0 through 1.6.1, REMOVED in 2.0.0
        // (which replaced pool-held liquidity with the external ILockBox deposit/withdraw model).
        if (op == Op.GET_REBALANCER) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.SET_REBALANCER) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.PROVIDE_LIQUIDITY) return (Version.V1_5_0, Version.V2_0_0);
        if (op == Op.WITHDRAW_LIQUIDITY) return (Version.V1_5_0, Version.V2_0_0);
        revert("PoolVersions: operation missing from the capability-range table");
    }

    /// @notice Whether `version` supports `op` per the capability-range table. `UNKNOWN` supports
    ///         nothing (write paths must never reach a dispatch with an unresolved version).
    function isSupported(Op op, Version version) internal pure returns (bool) {
        if (version == Version.UNKNOWN) return false;
        (Version introducedIn, Version removedIn) = opRange(op);
        if (version < introducedIn) return false;
        if (removedIn != Version.UNKNOWN && version >= removedIn) return false;
        return true;
    }

    /// @notice Reverts with the named unsupported-for-operation error when `version` does not
    ///         support `op`. The message carries the pool address, the version, the supported
    ///         range, and the fix procedure.
    function requireSupports(Op op, Version version, address pool) internal pure {
        if (isSupported(op, version)) return;
        (Version introducedIn, Version removedIn) = opRange(op);
        revert(
            string.concat(
                "UnsupportedPoolOperation: ",
                opName(op),
                " is not available on pool ",
                Strings.toHexString(pool),
                " (contract version ",
                toString(version),
                "). The operation exists on pool versions ",
                rangeString(introducedIn, removedIn),
                ". See ",
                DOCS,
                "#operation-ranges; the capability table lives in ",
                CATALOG,
                "."
            )
        );
    }

    /// @notice Parses an exact version token (e.g. `1.6.1`) to its catalog entry; `UNKNOWN` for
    ///         anything not cataloged (including `-dev` builds and empty strings).
    function fromVersionToken(string memory token) internal pure returns (Version) {
        bytes32 h = keccak256(bytes(token));
        if (h == keccak256(bytes("1.5.0"))) return Version.V1_5_0;
        if (h == keccak256(bytes("1.5.1"))) return Version.V1_5_1;
        if (h == keccak256(bytes("1.6.1"))) return Version.V1_6_1;
        if (h == keccak256(bytes("2.0.0"))) return Version.V2_0_0;
        return Version.UNKNOWN;
    }

    /// @notice The version token of a catalog entry, for logs and error messages.
    function toString(Version version) internal pure returns (string memory) {
        if (version == Version.V1_5_0) return "1.5.0";
        if (version == Version.V1_5_1) return "1.5.1";
        if (version == Version.V1_6_1) return "1.6.1";
        if (version == Version.V2_0_0) return "2.0.0";
        return "unknown";
    }

    /// @notice Human-readable `[introducedIn, removedIn)` range for error messages.
    function rangeString(Version introducedIn, Version removedIn) internal pure returns (string memory) {
        if (removedIn == Version.UNKNOWN) return string.concat(toString(introducedIn), " and later");
        return string.concat(toString(introducedIn), " up to but not including ", toString(removedIn));
    }

    /// @notice The operation name used in error messages.
    function opName(Op op) internal pure returns (string memory) {
        if (op == Op.APPLY_CHAIN_UPDATES) return "applyChainUpdates (modern removes/adds shape)";
        if (op == Op.APPLY_CHAIN_UPDATES_V150) return "applyChainUpdates (1.5.0 single-argument shape)";
        if (op == Op.ADD_REMOTE_POOL) return "addRemotePool";
        if (op == Op.REMOVE_REMOTE_POOL) return "removeRemotePool";
        if (op == Op.GET_REMOTE_POOLS) return "getRemotePools";
        if (op == Op.GET_REMOTE_POOL) return "getRemotePool (singular)";
        if (op == Op.SET_CHAIN_RATE_LIMITER_CONFIG) return "setChainRateLimiterConfig";
        if (op == Op.SET_RATE_LIMIT_CONFIG) return "setRateLimitConfig";
        if (op == Op.SET_ROUTER) return "setRouter";
        if (op == Op.SET_RATE_LIMIT_ADMIN) return "setRateLimitAdmin";
        if (op == Op.SET_DYNAMIC_CONFIG) return "setDynamicConfig";
        if (op == Op.APPLY_ALLOW_LIST_UPDATES_POOL) return "applyAllowListUpdates (pool-level)";
        if (op == Op.SET_TOKEN_TRANSFER_FEE_CONFIG) return "applyTokenTransferFeeConfigUpdates";
        if (op == Op.SET_ALLOWED_FINALITY_CONFIG) return "setAllowedFinalityConfig";
        if (op == Op.APPLY_CCV_CONFIG) return "applyCCVConfigUpdates";
        if (op == Op.SET_CCV_THRESHOLD) return "setThresholdAmount";
        if (op == Op.GET_REBALANCER) return "getRebalancer";
        if (op == Op.SET_REBALANCER) return "setRebalancer";
        if (op == Op.PROVIDE_LIQUIDITY) return "provideLiquidity";
        if (op == Op.WITHDRAW_LIQUIDITY) return "withdrawLiquidity";
        revert("PoolVersions: operation missing from the name table");
    }
}
