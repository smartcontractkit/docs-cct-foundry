// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {LaneReconcileScratch} from "./VerifyChainLaneReconcile.t.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";

contract MockSiloedLockBox {
    address internal immutable i_token;
    address[] internal s_callers;

    constructor(address token, address caller) {
        i_token = token;
        if (caller != address(0)) s_callers.push(caller);
    }

    function isTokenSupported(address token) external view returns (bool) {
        return token == i_token;
    }

    function getAllAuthorizedCallers() external view returns (address[] memory) {
        return s_callers;
    }

    function owner() external pure returns (address) {
        return address(0xA11CE);
    }
}

contract MockSiloedPool {
    struct LockBoxConfig {
        uint64 remoteChainSelector;
        address lockBox;
    }

    string internal s_version;
    address public token;
    uint64[] internal s_chains;
    LockBoxConfig[] internal s_boxes;

    constructor(string memory version, address token_) {
        s_version = version;
        token = token_;
    }

    function addChain(uint64 selector) external {
        s_chains.push(selector);
    }

    function mapBox(uint64 selector, address box) external {
        s_boxes.push(LockBoxConfig(selector, box));
    }

    function typeAndVersion() external view returns (string memory) {
        return s_version;
    }

    function getToken() external view returns (address) {
        return token;
    }

    function isSupportedChain(uint64 selector) external view returns (bool) {
        for (uint256 i = 0; i < s_chains.length; i++) {
            if (s_chains[i] == selector) return true;
        }
        return false;
    }

    function getSupportedChains() external view returns (uint64[] memory) {
        return s_chains;
    }

    function getAllLockBoxConfigs() external view returns (LockBoxConfig[] memory) {
        return s_boxes;
    }
}

/// @notice doctor's Siloed 2.0 lock box rung: every supported chain needs a box, and every box must hold the
/// pool token and authorize the pool. Supported chains are left undeclared, so each adds one lanes WARN.
contract VerifyChainSiloedLockBoxesTest is LaneReconcileScratch {
    address internal constant TOKEN = address(0x7070);
    uint64 internal constant CHAIN_A = 1_111_111;
    uint64 internal constant CHAIN_B = 2_222_222;

    function setUp() public {
        _cleanupScratchOne("zz-scratch-siloedbox");
    }

    function _pool(string memory version) internal returns (MockSiloedPool pool) {
        pool = new MockSiloedPool(version, TOKEN);
        pool.addChain(CHAIN_A);
        pool.addChain(CHAIN_B);
    }

    function _run(MockSiloedPool pool) internal returns (uint256 fails, uint256 warns) {
        _writeScratchChain("zz-scratch-siloedbox", 887_700_101, 8_877_001_010_000_000_001);
        (fails, warns) = new VerifyChain().checkLanesOnChainForTest("zz-scratch-siloedbox", address(pool));
        _cleanupScratchOne("zz-scratch-siloedbox");
    }

    function test_Pass_EveryChainMappedAndAuthorized() public {
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 2.0.0");
        pool.mapBox(CHAIN_A, address(new MockSiloedLockBox(TOKEN, address(pool))));
        pool.mapBox(CHAIN_B, address(new MockSiloedLockBox(TOKEN, address(pool))));
        (uint256 fails, uint256 warns) = _run(pool);
        assertEq(fails, 0, "no FAIL");
        // Two boxes, two undeclared lanes, and neither selector has a chain file here: the isolation rung
        // says so per chain rather than skipping the pair in silence.
        assertEq(warns, 4, "two undeclared-lane WARNs + two 'isolation not checked' WARNs");
    }

    function test_Fail_ChainWithoutLockBox() public {
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 2.0.0");
        pool.mapBox(CHAIN_A, address(new MockSiloedLockBox(TOKEN, address(pool))));
        (uint256 fails,) = _run(pool);
        assertEq(fails, 1, "chain B has no box");
    }

    function test_Fail_BoxDoesNotAuthorizePool() public {
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 2.0.0");
        pool.mapBox(CHAIN_A, address(new MockSiloedLockBox(TOKEN, address(pool))));
        pool.mapBox(CHAIN_B, address(new MockSiloedLockBox(TOKEN, address(0xBEEF))));
        (uint256 fails,) = _run(pool);
        assertEq(fails, 1, "box B does not authorize the pool");
    }

    function test_Fail_BoxHoldsAnotherToken() public {
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 2.0.0");
        pool.mapBox(CHAIN_A, address(new MockSiloedLockBox(TOKEN, address(pool))));
        pool.mapBox(CHAIN_B, address(new MockSiloedLockBox(address(0xD1FF), address(pool))));
        (uint256 fails,) = _run(pool);
        assertEq(fails, 1, "box B holds another token");
    }

    function test_Warn_BoxForUnsupportedChain() public {
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 2.0.0");
        address box = address(new MockSiloedLockBox(TOKEN, address(pool)));
        pool.mapBox(CHAIN_A, box);
        pool.mapBox(CHAIN_B, box);
        pool.mapBox(3_333_333, box);
        (uint256 fails, uint256 warns) = _run(pool);
        assertEq(fails, 0, "no FAIL");
        assertEq(warns, 3, "two undeclared lanes plus the stale mapping");
    }

    function test_Skip_LegacySiloedPool() public {
        // 1.6.x keeps liquidity on the pool; there are no lock boxes to reconcile.
        MockSiloedPool pool = _pool("SiloedLockReleaseTokenPool 1.6.1");
        (uint256 fails, uint256 warns) = _run(pool);
        assertEq(fails, 0, "no lock box FAIL on 1.6.1");
        assertEq(warns, 2, "only the undeclared-lane WARNs");
    }
}

/// @notice roles{}: `lockboxes` is keyed by box address and checked two-sided against the pool's map.
contract RolesSiloedLockBoxesTest is LaneReconcileScratch {
    function _json(address pool, string memory lockboxes) internal pure returns (string memory) {
        return string.concat('{"roles":{"pool":{"address":"', vm.toString(pool), '"},"lockboxes":', lockboxes, "}}");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return vm.indexOf(haystack, needle) != type(uint256).max;
    }

    function test_Pass_DeclaredMatchesPool() public {
        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", address(0x7070));
        address box = address(new MockSiloedLockBox(address(0x7070), address(pool)));
        pool.mapBox(1, box);
        pool.mapBox(2, box);
        string memory entry = string.concat(
            '{"',
            vm.toString(box),
            '":{"owner":"',
            vm.toString(address(0xA11CE)),
            '","authorizedCallers":["',
            vm.toString(address(pool)),
            '"]}}'
        );
        RolesAuditor.Result memory r =
            new RolesAuditor().auditJsonDeny("zz-scratch-roles-lb", _json(address(pool), entry), address(0));
        assertFalse(_contains(r.failedFields, "lockboxes"), r.failedFields);
    }

    function test_Fail_UndeclaredAndForeignBoxes() public {
        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", address(0x7070));
        pool.mapBox(1, address(new MockSiloedLockBox(address(0x7070), address(pool))));
        string memory entry = '{"0x000000000000000000000000000000000000dEaD":{}}';
        RolesAuditor.Result memory r =
            new RolesAuditor().auditJsonDeny("zz-scratch-roles-lb", _json(address(pool), entry), address(0));
        assertTrue(_contains(r.failedFields, "lockboxes.0x000000000000000000000000000000000000dEaD"), r.failedFields);
        assertTrue(_contains(r.failedFields, "lockboxes"), r.failedFields);
    }

    function test_Fail_DeclaredOnNonSiloedPool() public {
        MockSiloedPool notSiloed = MockSiloedPool(address(new MockSiloedLockBox(address(1), address(0))));
        RolesAuditor.Result memory r =
            new RolesAuditor().auditJsonDeny("zz-scratch-roles-lb", _json(address(notSiloed), "{}"), address(0));
        assertTrue(_contains(r.failedFields, "lockboxes"), r.failedFields);
    }
}
