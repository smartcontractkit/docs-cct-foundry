// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {SetFinalityConfig} from "../../script/configure/finality-config/SetFinalityConfig.s.sol";
import {LaneReconcileScratch} from "../config/VerifyChainLaneReconcile.t.sol";

/// @dev Exposes SetFinalityConfig's fast-finality divergence resolution. The resolution reads the
///      local chain config (files) and takes the applied buckets as parameters, so no env seam or
///      fork is needed: the test pins block.chainid to a uniquely-named scratch chain it writes.
contract FinalityRlDivergenceHarness is SetFinalityConfig {
    function resolve(
        RateLimiter.Config memory outbound,
        bool updateOutbound,
        RateLimiter.Config memory inbound,
        bool updateInbound,
        string memory destChainName,
        uint64 destChainSelector
    ) external view returns (FastFinalityRlDivergence memory) {
        return _resolveFastFinalityDivergence(
            outbound, updateOutbound, inbound, updateInbound, destChainName, destChainSelector
        );
    }
}

/// @notice SetFinalityConfig's fast-finality rate-limit reconciliation (env-override path only):
///         when an env-applied fast-finality bucket contradicts a declared
///         `lanes.<remote>.v2.fastFinality.<dir>` policy, the divergence notice + closing hand-edit
///         hint fire (byte-exact the wording UpdateRateLimiters prints); an agreeing declaration, an
///         absent v2 block, and an un-applied direction are all silent. Never sources a bucket from
///         lanes{} (no rung-2). Each test writes its own uniquely-named scratch chain and pins
///         block.chainid to it (test-local, no process-global state).
contract SetFinalityConfigFastFinalityTest is LaneReconcileScratch {
    uint64 internal constant REMOTE_SELECTOR = 8_874_000_000_000_000_001;
    uint128 internal constant ENV_CAPACITY = 5000e18;
    uint128 internal constant ENV_RATE = 50e18;
    uint128 internal constant FTF_CAPACITY = 300e18;
    uint128 internal constant FTF_RATE = 3e18;

    FinalityRlDivergenceHarness internal harness;

    function setUp() public {
        string[] memory names = new string[](6);
        for (uint256 n = 1; n <= 6; n++) {
            names[n - 1] = string.concat("zz-scratch-ffdiv-l", vm.toString(n));
        }
        _cleanupScratch(names);
        harness = new FinalityRlDivergenceHarness();
    }

    function _localChain(uint256 n) internal returns (string memory name) {
        name = string.concat("zz-scratch-ffdiv-l", vm.toString(n));
        uint256 chainId = 887_401_000 + n * 100 + 1;
        _writeScratchChain(name, chainId, uint64(8_874_010_000_000_000_000 + n * 100 + 1));
        vm.chainId(chainId);
    }

    /// @dev A `,"v2":{"fastFinality":{"outbound":{...}}}` suffix declaring only the outbound bucket.
    function _ftfOutboundBlock(uint256 capacity, uint256 rate) internal pure returns (string memory) {
        return string.concat(
            ",\"v2\":{\"fastFinality\":{\"outbound\":{\"capacity\":\"",
            vm.toString(capacity),
            "\",\"rate\":\"",
            vm.toString(rate),
            "\"}}}"
        );
    }

    function _enabled(uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate});
    }

    function _disabled() internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
    }

    // Env-applied outbound bucket contradicts the declared v2.fastFinality.outbound: notice + hint
    // fire, byte-exact the UpdateRateLimiters wording.
    function test_EnvDivergesDeclaredFastFinality_NoticeAndHintFire() public {
        string memory local = _localChain(1);
        _declareLane(
            local,
            "zz-scratch-ffdiv-remote1",
            _laneEntry(REMOTE_SELECTOR, 0, 0, _ftfOutboundBlock(FTF_CAPACITY, FTF_RATE))
        );

        SetFinalityConfig.FastFinalityRlDivergence memory res = harness.resolve(
            _enabled(ENV_CAPACITY, ENV_RATE), true, _disabled(), false, "zz-scratch-ffdiv-remote1", REMOTE_SELECTOR
        );

        assertTrue(res.laneFound, "lane entry must match by key name");
        assertTrue(res.outboundDeclared, "declared fast-finality outbound must be read");
        assertTrue(res.outboundDiverges, "diverging env override must be flagged");
        assertTrue(res.editHint, "divergence must arm the hint");
        assertEq(
            res.outboundNotice,
            string.concat(
                unicode"⚠️  OUTBOUND rate-limit env override (enabled=true capacity=",
                vm.toString(uint256(ENV_CAPACITY)),
                " rate=",
                vm.toString(uint256(ENV_RATE)),
                ") diverges from declared lanes.zz-scratch-ffdiv-remote1.v2.fastFinality.outbound (capacity=",
                vm.toString(uint256(FTF_CAPACITY)),
                " rate=",
                vm.toString(uint256(FTF_RATE)),
                ") in config/chains/",
                local,
                ".json - make doctor will WARN until reconciled"
            ),
            "composed fast-finality divergence notice"
        );
        assertEq(
            res.outboundHint,
            string.concat(
                unicode"⚠️  Applied OUTBOUND values are diverging from lanes.zz-scratch-ffdiv-remote1.v2.fastFinality.outbound (config/chains/",
                local,
                ".json). Hand-edit the entry to capacity=",
                vm.toString(uint256(ENV_CAPACITY)),
                " rate=",
                vm.toString(uint256(ENV_RATE)),
                " - make doctor CHAIN=",
                local,
                " WARNs until reconciled"
            ),
            "composed fast-finality edit hint"
        );

        vm.removeFile(_path(local));
    }

    // Env-applied outbound bucket AGREES with the declared v2.fastFinality.outbound: silent.
    function test_EnvAgreesDeclaredFastFinality_Silent() public {
        string memory local = _localChain(2);
        _declareLane(
            local,
            "zz-scratch-ffdiv-remote2",
            _laneEntry(REMOTE_SELECTOR, 0, 0, _ftfOutboundBlock(ENV_CAPACITY, ENV_RATE))
        );

        SetFinalityConfig.FastFinalityRlDivergence memory res = harness.resolve(
            _enabled(ENV_CAPACITY, ENV_RATE), true, _disabled(), false, "zz-scratch-ffdiv-remote2", REMOTE_SELECTOR
        );

        assertTrue(res.outboundDeclared, "declaration read");
        assertFalse(res.outboundDiverges, "agreeing env override must not diverge");
        assertFalse(res.editHint, "no divergence, no hint");
        assertEq(res.outboundNotice, "", "no notice");
        assertEq(res.outboundHint, "", "no hint");

        vm.removeFile(_path(local));
    }

    // No v2.fastFinality block declared (core-only lane): silent — the core fields never count as a
    // fast-finality declaration, so an env override cannot diverge from an absent declaration.
    function test_NoFastFinalityDeclaration_Silent() public {
        string memory local = _localChain(3);
        _declareLane(local, "zz-scratch-ffdiv-remote3", _laneEntry(REMOTE_SELECTOR, ENV_CAPACITY, ENV_RATE, ""));

        SetFinalityConfig.FastFinalityRlDivergence memory res = harness.resolve(
            _enabled(ENV_CAPACITY, ENV_RATE), true, _disabled(), false, "zz-scratch-ffdiv-remote3", REMOTE_SELECTOR
        );

        assertTrue(res.laneFound, "lane matched");
        assertFalse(res.outboundDeclared, "core fields are not a fast-finality declaration");
        assertFalse(res.outboundDiverges, "nothing declared, nothing to diverge from");
        assertFalse(res.editHint, "no hint");

        vm.removeFile(_path(local));
    }

    // No lanes{} entry at all: silent (nothing to reconcile against).
    function test_NoLaneEntry_Silent() public {
        string memory local = _localChain(4);

        SetFinalityConfig.FastFinalityRlDivergence memory res = harness.resolve(
            _enabled(ENV_CAPACITY, ENV_RATE), true, _disabled(), false, "zz-scratch-ffdiv-none4", REMOTE_SELECTOR
        );

        assertFalse(res.laneFound, "no lane entry to find");
        assertFalse(res.outboundDiverges, "no declaration, no divergence");
        assertFalse(res.editHint, "no hint");

        vm.removeFile(_path(local));
    }

    // A direction that was NOT env-applied does not diverge, even against a disagreeing declaration:
    // reconciliation is scoped to the env-override buckets actually written.
    function test_UnappliedDirection_DoesNotDiverge() public {
        string memory local = _localChain(5);
        _declareLane(
            local,
            "zz-scratch-ffdiv-remote5",
            _laneEntry(REMOTE_SELECTOR, 0, 0, _ftfOutboundBlock(FTF_CAPACITY, FTF_RATE))
        );

        // outbound applied bucket differs from the declaration, but updateOutbound=false.
        SetFinalityConfig.FastFinalityRlDivergence memory res = harness.resolve(
            _enabled(ENV_CAPACITY, ENV_RATE), false, _disabled(), false, "zz-scratch-ffdiv-remote5", REMOTE_SELECTOR
        );

        assertTrue(res.outboundDeclared, "declaration read");
        assertFalse(res.outboundDiverges, "an un-applied direction never diverges");
        assertFalse(res.editHint, "no hint");

        vm.removeFile(_path(local));
    }
}
