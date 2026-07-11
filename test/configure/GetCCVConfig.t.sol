// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {GetCCVConfig} from "../../script/configure/ccv/GetCCVConfig.s.sol";

/// @dev A 2.0.0 pool answering the getter's version fence, with a settable AdvancedPoolHooks address
///      (address(0) exercises the graceful no-hooks path; a real hooks address the configured path).
contract MockV2Pool {
    address private immutable i_hooks;

    constructor(address hooks) {
        i_hooks = hooks;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.0.0";
    }

    function getAdvancedPoolHooks() external view returns (address) {
        return i_hooks;
    }
}

/// @dev A 2.0.0 pool whose `getAdvancedPoolHooks` REVERTS (rather than returning address(0)): the
///      getter must catch it and degrade to the graceful no-hooks message, never re-revert.
contract MockV2HooksRevertPool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 2.0.0";
    }

    function getAdvancedPoolHooks() external pure returns (address) {
        revert("getAdvancedPoolHooks unavailable");
    }
}

/// @dev A pre-2.0.0 pool: the getter degrades with a named "pre-2.0.0" message (no revert).
contract MockCcv150Pool {
    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.5.0";
    }
}

/// @notice The CCV read/display path of GetCCVConfig, driven through its `displayForTest` seam against
///         an explicit pool on the currently-selected chain. The getter is version-fenced and MUST
///         degrade gracefully (never revert) on every off-nominal shape: a pre-2.0.0 pool, a 2.0.0 pool
///         with no hooks wired, and a 2.0.0 pool whose `getAdvancedPoolHooks` itself reverts. It reads
///         back a real AdvancedPoolHooks fixture's lane arrays + pool-global threshold on the happy path.
///         Pins block.chainid to Ethereum Sepolia (a HelperConfig fast-path chain) so the header/footer
///         chain + explorer resolution succeeds without any scratch config file.
contract GetCCVConfigTest is Test {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint64 internal constant REMOTE_SELECTOR = 8_876_000_000_000_000_001;
    address internal constant CCV1 = address(0xCC01);
    address internal constant CCV2 = address(0xCC02);

    GetCCVConfig internal getter;

    function setUp() public {
        vm.chainId(SEPOLIA_CHAIN_ID);
        getter = new GetCCVConfig();
    }

    /// (a) A 2.0.0 pool with NO hooks wired: the getter degrades gracefully, never reverting.
    function test_Display_NoHooks_DegradesGracefully() public {
        MockV2Pool pool = new MockV2Pool(address(0));
        // No revert = pass; the getter prints the graceful no-hooks message and returns.
        getter.displayForTest(address(pool));
    }

    /// A pre-2.0.0 pool: the getter degrades with the named pre-2.0.0 message, never reverting.
    function test_Display_Pre200Pool_DegradesGracefully() public {
        MockCcv150Pool pool = new MockCcv150Pool();
        getter.displayForTest(address(pool));
    }

    /// (b) A real AdvancedPoolHooks fixture with a configured lane + non-zero threshold: the getter
    ///     reads it back through the full display path (getAllCCVConfigs + getThresholdAmount) with no
    ///     revert. The fixture state is asserted directly to document what the getter read.
    function test_Display_ConfiguredHooks_ReadsBackLaneAndThreshold() public {
        uint256 threshold = 1000e18;
        address[] memory authorizedCallers = new address[](1);
        authorizedCallers[0] = address(this);
        AdvancedPoolHooks hooks = new AdvancedPoolHooks(new address[](0), threshold, address(0), authorizedCallers);

        address[] memory outbound = new address[](2);
        outbound[0] = CCV1;
        outbound[1] = CCV2;
        AdvancedPoolHooks.CCVConfigArg[] memory args = new AdvancedPoolHooks.CCVConfigArg[](1);
        args[0] = AdvancedPoolHooks.CCVConfigArg({
            remoteChainSelector: REMOTE_SELECTOR,
            outboundCCVs: outbound,
            thresholdOutboundCCVs: new address[](0),
            inboundCCVs: new address[](0),
            thresholdInboundCCVs: new address[](0)
        });
        hooks.applyCCVConfigUpdates(args);

        // The getter had real data to read back.
        assertEq(hooks.getThresholdAmount(), threshold, "fixture threshold");
        assertEq(hooks.getAllCCVConfigs().length, 1, "fixture has one configured lane");

        MockV2Pool pool = new MockV2Pool(address(hooks));
        // No revert = the full read/display path (header, hooks resolve, getAllCCVConfigs loop, footer)
        // executed against a populated hooks contract.
        getter.displayForTest(address(pool));
    }

    /// (c) A 2.0.0 pool whose getAdvancedPoolHooks REVERTS: the getter catches it and degrades to the
    ///     graceful no-hooks message instead of re-reverting (read path never reverts).
    function test_Display_HooksReadReverts_DegradesGracefully() public {
        MockV2HooksRevertPool pool = new MockV2HooksRevertPool();
        // Sanity: the pool's hooks read really does revert.
        vm.expectRevert(bytes("getAdvancedPoolHooks unavailable"));
        pool.getAdvancedPoolHooks();
        // The getter must NOT propagate that revert.
        getter.displayForTest(address(pool));
    }
}
