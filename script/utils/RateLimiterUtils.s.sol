// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";

/// @dev Minimal interface for v1 TokenPool rate limiter functions that were replaced in v2.
interface ITokenPoolV1RateLimiter {
    function getCurrentOutboundRateLimiterState(uint64 remoteChainSelector)
        external
        view
        returns (RateLimiter.TokenBucket memory);

    function getCurrentInboundRateLimiterState(uint64 remoteChainSelector)
        external
        view
        returns (RateLimiter.TokenBucket memory);

    function setChainRateLimiterConfig(
        uint64 remoteChainSelector,
        RateLimiter.Config memory outboundConfig,
        RateLimiter.Config memory inboundConfig
    ) external;
}

library RateLimiterUtils {
    // Access the forge-std vm cheatcode from within a library.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Parameters for a rate limiter update, used by scripts that modify rate limits.
    /// Direction is inferred from which fields are set: updateOutbound / updateInbound act as flags.
    /// isEnabled defaults to true when capacity or rate are provided.
    struct RateLimitUpdate {
        bool updateOutbound;
        bool outboundEnabled;
        uint128 outboundCapacity;
        uint128 outboundRate;
        bool updateInbound;
        bool inboundEnabled;
        uint128 inboundCapacity;
        uint128 inboundRate;
    }

    /// @dev Reads optional rate limit env vars using a sentinel to detect which were actually set.
    /// Direction is inferred from any OUTBOUND_* / INBOUND_* var being present.
    /// isEnabled defaults to true when CAPACITY or RATE are provided; override with ENABLED=false.
    function _readRateLimitUpdate() internal view returns (RateLimitUpdate memory u) {
        string memory sentinel = "__not_set__";
        bool outboundEnabledSet =
            keccak256(bytes(VM.envOr("OUTBOUND_RATE_LIMIT_ENABLED", sentinel))) != keccak256(bytes(sentinel));
        bool outboundCapacitySet =
            keccak256(bytes(VM.envOr("OUTBOUND_RATE_LIMIT_CAPACITY", sentinel))) != keccak256(bytes(sentinel));
        bool outboundRateSet =
            keccak256(bytes(VM.envOr("OUTBOUND_RATE_LIMIT_RATE", sentinel))) != keccak256(bytes(sentinel));
        bool inboundEnabledSet =
            keccak256(bytes(VM.envOr("INBOUND_RATE_LIMIT_ENABLED", sentinel))) != keccak256(bytes(sentinel));
        bool inboundCapacitySet =
            keccak256(bytes(VM.envOr("INBOUND_RATE_LIMIT_CAPACITY", sentinel))) != keccak256(bytes(sentinel));
        bool inboundRateSet =
            keccak256(bytes(VM.envOr("INBOUND_RATE_LIMIT_RATE", sentinel))) != keccak256(bytes(sentinel));

        u.updateOutbound = outboundEnabledSet || outboundCapacitySet || outboundRateSet;
        u.updateInbound = inboundEnabledSet || inboundCapacitySet || inboundRateSet;

        if (u.updateOutbound) {
            u.outboundEnabled = VM.envOr("OUTBOUND_RATE_LIMIT_ENABLED", outboundCapacitySet || outboundRateSet);
            u.outboundCapacity = uint128(VM.envOr("OUTBOUND_RATE_LIMIT_CAPACITY", uint256(0)));
            u.outboundRate = uint128(VM.envOr("OUTBOUND_RATE_LIMIT_RATE", uint256(0)));
        }
        if (u.updateInbound) {
            u.inboundEnabled = VM.envOr("INBOUND_RATE_LIMIT_ENABLED", inboundCapacitySet || inboundRateSet);
            u.inboundCapacity = uint128(VM.envOr("INBOUND_RATE_LIMIT_CAPACITY", uint256(0)));
            u.inboundRate = uint128(VM.envOr("INBOUND_RATE_LIMIT_RATE", uint256(0)));
        }
    }

    /// @notice Returns the current outbound and inbound TokenBuckets for a given lane, dispatched
    /// on the resolved pool contract version (v2 getter from 2.0.0, per-direction v1 getters
    /// before). `UNKNOWN` is legal here because reads degrade instead of refusing: it falls back
    /// to best effort (v2 getter first, v1 getters when that reverts).
    /// @param poolV2 The pool cast as the v2 TokenPool type.
    /// @param poolV1 The pool cast as the v1 interface.
    /// @param remoteChainSelector The remote chain selector to query.
    /// @param fastFinality Whether to query the fast finality bucket (v2 only).
    /// @param version The pool contract version resolved by `PoolVersion._resolve`/`tryResolve`.
    function _getCurrentBuckets(
        TokenPool poolV2,
        ITokenPoolV1RateLimiter poolV1,
        uint64 remoteChainSelector,
        bool fastFinality,
        PoolVersions.Version version
    ) internal view returns (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) {
        if (version >= PoolVersions.Version.V2_0_0) {
            (outbound, inbound) = poolV2.getCurrentRateLimiterState(remoteChainSelector, fastFinality);
        } else if (version != PoolVersions.Version.UNKNOWN) {
            outbound = poolV1.getCurrentOutboundRateLimiterState(remoteChainSelector);
            inbound = poolV1.getCurrentInboundRateLimiterState(remoteChainSelector);
        } else {
            try poolV2.getCurrentRateLimiterState(remoteChainSelector, fastFinality) returns (
                RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i
            ) {
                (outbound, inbound) = (o, i);
            } catch {
                outbound = poolV1.getCurrentOutboundRateLimiterState(remoteChainSelector);
                inbound = poolV1.getCurrentInboundRateLimiterState(remoteChainSelector);
            }
        }
    }

    /// @notice Returns the current outbound and inbound rate limiter configs for a given lane.
    /// Converts TokenBucket → Config (drops the live token fill level, which is not needed for updates).
    function _getCurrentConfigs(
        TokenPool poolV2,
        ITokenPoolV1RateLimiter poolV1,
        uint64 remoteChainSelector,
        bool fastFinality,
        PoolVersions.Version version
    ) internal view returns (RateLimiter.Config memory outbound, RateLimiter.Config memory inbound) {
        (RateLimiter.TokenBucket memory ob, RateLimiter.TokenBucket memory ib) =
            _getCurrentBuckets(poolV2, poolV1, remoteChainSelector, fastFinality, version);
        outbound = RateLimiter.Config({isEnabled: ob.isEnabled, capacity: ob.capacity, rate: ob.rate});
        inbound = RateLimiter.Config({isEnabled: ib.isEnabled, capacity: ib.capacity, rate: ib.rate});
    }

    /// @notice Logs the current rate limiter state for a given remote chain, compatible with v1 and v2 pools.
    /// Reuses the already-resolved version to avoid a redundant RPC call.
    function _logRateLimiterState(
        TokenPool poolV2,
        ITokenPoolV1RateLimiter poolV1,
        uint64 remoteChainSelector,
        bool fastFinality,
        PoolVersions.Version version
    ) internal view {
        console.log("Current Rate Limiter State:");
        (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) =
            _getCurrentBuckets(poolV2, poolV1, remoteChainSelector, fastFinality, version);
        _logBucket("Outbound", outbound);
        _logBucket("Inbound ", inbound);
        console.log("");
    }

    /// @dev Logs rate limiter state with per-direction fallback: shows the custom finality bucket
    /// for each direction where it is enabled; shows the standard bucket for directions where it is not.
    /// This mirrors the on-chain behaviour of TokenPool v2 - transfers fall back to the standard
    /// bucket when the custom finality bucket is not configured for that direction.
    /// For v1 pools (no custom finality concept) the standard bucket is always shown.
    function _logRateLimiterStateWithFallback(
        TokenPool poolV2,
        ITokenPoolV1RateLimiter poolV1,
        uint64 remoteChainSelector,
        PoolVersions.Version version
    ) internal view {
        if (version < PoolVersions.Version.V2_0_0) {
            (RateLimiter.TokenBucket memory ob, RateLimiter.TokenBucket memory ib) =
                _getCurrentBuckets(poolV2, poolV1, remoteChainSelector, false, version);
            _logBucket("Outbound [standard]", ob);
            _logBucket("Inbound  [standard]", ib);
            console.log("");
            return;
        }

        (RateLimiter.TokenBucket memory customOut, RateLimiter.TokenBucket memory customIn) =
            poolV2.getCurrentRateLimiterState(remoteChainSelector, true);

        // Only fetch standard buckets when at least one direction needs the fallback.
        RateLimiter.TokenBucket memory stdOut;
        RateLimiter.TokenBucket memory stdIn;
        if (!customOut.isEnabled || !customIn.isEnabled) {
            (stdOut, stdIn) = poolV2.getCurrentRateLimiterState(remoteChainSelector, false);
        }

        if (customOut.isEnabled) {
            _logBucketGroup("Outbound [custom finality]", customOut);
        } else {
            _logBucketGroup("Outbound [standard fallback]", stdOut);
        }
        if (customIn.isEnabled) {
            _logBucketGroup("Inbound [custom finality]", customIn);
        } else {
            _logBucketGroup("Inbound [standard fallback]", stdIn);
        }
        console.log("");
    }

    /// @dev Logs individual bucket fields inline (label prefix per line).
    function _logBucket(string memory label, RateLimiter.TokenBucket memory bucket) internal pure {
        console.log(string.concat("  ", label, " Enabled:  ", bucket.isEnabled ? "true" : "false"));
        console.log(string.concat("  ", label, " Capacity: ", VM.toString(bucket.capacity)));
        console.log(string.concat("  ", label, " Rate:     ", VM.toString(bucket.rate)));
        console.log(string.concat("  ", label, " Tokens:   ", VM.toString(bucket.tokens)));
    }

    /// @dev Logs a bucket with the label as a header and fields indented beneath it.
    /// Used when mixing custom-finality and standard-fallback directions so that
    /// field values align consistently regardless of label length.
    function _logBucketGroup(string memory label, RateLimiter.TokenBucket memory bucket) internal pure {
        console.log(string.concat("  ", label, ":"));
        console.log(string.concat("    Enabled:  ", bucket.isEnabled ? "true" : "false"));
        console.log(string.concat("    Capacity: ", VM.toString(bucket.capacity)));
        console.log(string.concat("    Rate:     ", VM.toString(bucket.rate)));
        console.log(string.concat("    Tokens:   ", VM.toString(bucket.tokens)));
    }

    /// @notice Returns a human-readable label for the rate limiter direction.
    function _directionLabel(bool updateOutbound, bool updateInbound) internal pure returns (string memory) {
        if (updateOutbound && updateInbound) return "Outbound + Inbound";
        if (updateOutbound) return "Outbound only";
        return "Inbound only";
    }

    /// @notice Logs the new rate limiter config that will be applied.
    /// @param updateOutbound Whether the outbound direction is being updated.
    /// @param outbound The new outbound config.
    /// @param updateInbound Whether the inbound direction is being updated.
    /// @param inbound The new inbound config.
    function _logNewConfig(
        bool updateOutbound,
        RateLimiter.Config memory outbound,
        bool updateInbound,
        RateLimiter.Config memory inbound
    ) internal pure {
        console.log("New Configuration:");
        if (updateOutbound) {
            console.log(string.concat("  Outbound Enabled:  ", outbound.isEnabled ? "true" : "false"));
            if (outbound.isEnabled) {
                console.log(string.concat("  Outbound Capacity: ", VM.toString(outbound.capacity)));
                console.log(string.concat("  Outbound Rate:     ", VM.toString(outbound.rate)));
            }
        }
        if (updateInbound) {
            console.log(string.concat("  Inbound Enabled:   ", inbound.isEnabled ? "true" : "false"));
            if (inbound.isEnabled) {
                console.log(string.concat("  Inbound Capacity:  ", VM.toString(inbound.capacity)));
                console.log(string.concat("  Inbound Rate:      ", VM.toString(inbound.rate)));
            }
        }
        console.log("");
    }
}
