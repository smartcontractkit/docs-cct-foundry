// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";
import {ForgetDeployment} from "../../script/config/ForgetDeployment.s.sol";

contract ForgetHarness {
    function record(string memory sel, string memory role, string memory name, address addr) external {
        RegistryWriter._recordDeterministic(sel, role, name, addr);
    }

    function setDeployment(string memory sel, string memory name, address addr) external {
        RegistryWriter._setDeployment(sel, name, addr);
    }

    function forget(string memory sel, string memory name) external returns (string memory) {
        return RegistryWriter._forgetDeployment(sel, name);
    }

    function readDeployment(string memory sel, string memory name) external view returns (address) {
        return RegistryWriter._readDeployment(sel, name);
    }

    function read(string memory sel, string memory role) external view returns (address) {
        return RegistryWriter._read(sel, role);
    }
}

contract MockRegistry {
    address public registered;

    constructor(address pool) {
        registered = pool;
    }

    function getPool(address) external view returns (address) {
        return registered;
    }
}

contract MockPool {
    uint64[] internal s_chains;

    constructor(uint256 n) {
        for (uint256 i = 0; i < n; i++) {
            s_chains.push(uint64(i + 1));
        }
    }

    function getSupportedChains() external view returns (uint64[] memory) {
        return s_chains;
    }
}

contract MockBalanceToken {
    uint256 public held;

    constructor(uint256 amount) {
        held = amount;
    }

    function balanceOf(address) external view returns (uint256) {
        return held;
    }
}

/// @notice `make forget-deployment`: removes one retired `deployments{}` entry and nothing else, and refuses
/// anything still in use, in the store or on-chain.
contract ForgetDeploymentTest is Test {
    string internal constant SEL_REMOVE = "zz-scratch-forget-remove";
    string internal constant SEL_ACTIVE = "zz-scratch-forget-active";
    string internal constant SEL_ABSENT = "zz-scratch-forget-absent";
    address internal constant TOKEN = address(0x1111111111111111111111111111111111111111);
    address internal constant OLD_POOL = address(0x2222222222222222222222222222222222222222);
    address internal constant NEW_POOL = address(0x3333333333333333333333333333333333333333);

    ForgetHarness internal harness;
    ForgetDeployment internal script;

    function setUp() public {
        harness = new ForgetHarness();
        script = new ForgetDeployment();
        ProjectScratch.clean(SEL_REMOVE);
        ProjectScratch.clean(SEL_ACTIVE);
        ProjectScratch.clean(SEL_ABSENT);
    }

    function test_RemovesOnlyTheRetiredEntry() public {
        harness.record(SEL_REMOVE, "token", "WBTC_Token", TOKEN);
        harness.setDeployment(SEL_REMOVE, "WBTC_BurnMintTokenPool_1.5.1", OLD_POOL);
        harness.record(SEL_REMOVE, "tokenPool", "WBTC_BurnMintTokenPool_2.0.0", NEW_POOL);

        harness.forget(SEL_REMOVE, "WBTC_BurnMintTokenPool_1.5.1");

        assertEq(harness.readDeployment(SEL_REMOVE, "WBTC_BurnMintTokenPool_1.5.1"), address(0), "old entry gone");
        assertEq(harness.readDeployment(SEL_REMOVE, "WBTC_BurnMintTokenPool_2.0.0"), NEW_POOL, "new entry kept");
        assertEq(harness.read(SEL_REMOVE, "tokenPool"), NEW_POOL, "active pointer kept");
        assertEq(harness.read(SEL_REMOVE, "token"), TOKEN, "token kept");
        ProjectScratch.clean(SEL_REMOVE);
    }

    function test_RefusesTheActiveEntry() public {
        harness.record(SEL_ACTIVE, "tokenPool", "WBTC_BurnMintTokenPool_2.0.0", NEW_POOL);
        vm.expectRevert(
            bytes(
                "RegistryWriter: 'WBTC_BurnMintTokenPool_2.0.0' is active.tokenPool - point that role elsewhere before forgetting it"
            )
        );
        harness.forget(SEL_ACTIVE, "WBTC_BurnMintTokenPool_2.0.0");
        ProjectScratch.clean(SEL_ACTIVE);
    }

    function test_RefusesAnAbsentEntry() public {
        harness.record(SEL_ABSENT, "token", "WBTC_Token", TOKEN);
        vm.expectRevert();
        harness.forget(SEL_ABSENT, "WBTC_BurnMintTokenPool_9.9.9");
        ProjectScratch.clean(SEL_ABSENT);
    }

    function test_LiveUse_StillRegisteredPool() public {
        MockPool pool = new MockPool(0);
        MockRegistry tar = new MockRegistry(address(pool));
        string memory reason = script.liveUseReason("WBTC_BurnMintTokenPool_1.5.1", address(pool), TOKEN, address(tar));
        assertTrue(bytes(reason).length > 0, "registered pool refused");
        assertTrue(vm.indexOf(reason, "TokenAdminRegistry routes to") != type(uint256).max, reason);
    }

    function test_LiveUse_PoolWithLanes() public {
        MockPool pool = new MockPool(2);
        MockRegistry tar = new MockRegistry(NEW_POOL);
        string memory reason = script.liveUseReason("WBTC_BurnMintTokenPool_1.5.1", address(pool), TOKEN, address(tar));
        assertTrue(vm.indexOf(reason, "still supports 2 remote chain(s)") != type(uint256).max, reason);
    }

    function test_LiveUse_RetiredPoolIsSafe() public {
        MockPool pool = new MockPool(0);
        MockRegistry tar = new MockRegistry(NEW_POOL);
        assertEq(script.liveUseReason("WBTC_BurnMintTokenPool_1.5.1", address(pool), TOKEN, address(tar)), "");
    }

    function test_LiveUse_FundedLockBox() public {
        MockBalanceToken token = new MockBalanceToken(5);
        string memory reason = script.liveUseReason("WBTC_LockBox_fuji", address(0xB0B), address(token), address(0));
        assertTrue(vm.indexOf(reason, "still holds 5") != type(uint256).max, reason);
        MockBalanceToken empty = new MockBalanceToken(0);
        assertEq(script.liveUseReason("WBTC_LockBox_fuji", address(0xB0B), address(empty), address(0)), "");
    }

    function test_LiveUse_NonPoolAnswersNothing() public view {
        // An address with no code is not a live pool; nothing to protect.
        assertEq(script.liveUseReason("WBTC_BurnMintTokenPool_1.5.1", address(0xDEAD), TOKEN, address(0)), "");
    }
}
