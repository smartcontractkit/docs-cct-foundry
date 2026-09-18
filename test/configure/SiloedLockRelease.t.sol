// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {SiloedLockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/SiloedLockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {CctActions, ISiloedLockReleaseV16} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {PoolVersion} from "../../script/utils/PoolVersion.s.sol";
import {DeployLegacyPool} from "../fixtures/legacy/DeployLegacyPool.s.sol";

contract SiloedResolverShim {
    function resolve(address pool) external view returns (PoolVersions.Version v, string memory full) {
        return PoolVersion._resolve(pool);
    }

    function requireSiloed(address pool, PoolVersions.Op op) external view returns (PoolVersions.Version v) {
        (v,) = PoolVersion._requireSiloed(pool, op);
    }
}

/// @notice The legacy Siloed pools a partner runs today (1.6.0, 1.6.1) and the 2.0.0 target, driven through
///         the repo's resolver and action layer on a Sepolia fork, with WBTC mainnet's rate limits.
contract SiloedLockReleaseForkTest is BaseForkTest {
    uint64 internal constant FUJI = 14767482510784806043;
    uint64 internal constant BASE = 10344971235874465080;
    // WBTC Ethereum -> Ronin on mainnet, 8 decimals.
    uint128 internal constant OUT_CAPACITY = 3_780_000_000;
    uint128 internal constant OUT_RATE = 43_750;
    uint128 internal constant IN_CAPACITY = 4_200_000_000;
    uint128 internal constant IN_RATE = 48_610;

    SiloedResolverShim internal shim;
    address internal token;
    address internal owner;

    function setUp() public override {
        super.setUp();
        shim = new SiloedResolverShim();
        token = deployTokenFixture();
        owner = _scriptBroadcaster();
        _exec(owner, CctActions._mint(token, owner, 10e8));
    }

    function _legacy(string memory kind) internal returns (address) {
        return new DeployLegacyPool().run(kind, token);
    }

    function _wire(address pool, PoolVersions.Version v, uint64 remote) internal {
        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(address(0xBEEF));
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remote,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(address(0xCAFE)),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: OUT_CAPACITY, rate: OUT_RATE}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: IN_CAPACITY, rate: IN_RATE})
        });
        PoolVersions._requireSupports(PoolVersions.Op.APPLY_CHAIN_UPDATES, v, pool);
        _exec(owner, CctActions._applyChainUpdates(pool, new uint64[](0), adds));
    }

    function test_Legacy_ResolveAndWire() public {
        string[2] memory kinds = ["siloed-1.6.0", "siloed-1.6.1"];
        PoolVersions.Version[2] memory expected = [PoolVersions.Version.V1_6_0, PoolVersions.Version.V1_6_1];
        for (uint256 i = 0; i < 2; i++) {
            address pool = _legacy(kinds[i]);
            (PoolVersions.Version v,) = shim.resolve(pool);
            assertEq(uint256(v), uint256(expected[i]), kinds[i]);
            _wire(pool, v, FUJI);
            assertTrue(TokenPool(pool).isSupportedChain(FUJI), "lane added");

            // A day-2 rate-limit change through the version-dispatched builder.
            RateLimiter.Config memory out =
                RateLimiter.Config({isEnabled: true, capacity: 2 * OUT_CAPACITY, rate: OUT_RATE});
            RateLimiter.Config memory inb = RateLimiter.Config({isEnabled: true, capacity: IN_CAPACITY, rate: IN_RATE});
            _exec(owner, CctActions._setRateLimits(pool, v, FUJI, false, out, inb));
            (bool ok, bytes memory ret) =
                pool.staticcall(abi.encodeWithSignature("getCurrentOutboundRateLimiterState(uint64)", FUJI));
            assertTrue(ok, "v1 getter");
            (,,, uint128 capacity,) = abi.decode(ret, (uint128, uint32, bool, uint128, uint128));
            assertEq(capacity, 2 * OUT_CAPACITY, "outbound capacity updated");
        }
    }

    /// @dev 1.6.0 kept the 1.5.x validation; 1.6.1 relaxed it. A `capacity=1, rate=1` pause is 1.6.1-only.
    function test_Legacy_PauseThrottleDiffersBy160() public {
        address p160 = _legacy("siloed-1.6.0");
        address p161 = _legacy("siloed-1.6.1");
        _wire(p160, PoolVersions.Version.V1_6_0, FUJI);
        _wire(p161, PoolVersions.Version.V1_6_1, FUJI);
        RateLimiter.Config memory pause = RateLimiter.Config({isEnabled: true, capacity: 1, rate: 1});

        CctActions.Call[] memory c160 =
            CctActions._setRateLimits(p160, PoolVersions.Version.V1_6_0, FUJI, false, pause, pause);
        vm.prank(owner);
        (bool ok,) = c160[0].target.call(c160[0].data);
        assertFalse(ok, "1.6.0 rejects rate >= capacity");

        _exec(owner, CctActions._setRateLimits(p161, PoolVersions.Version.V1_6_1, FUJI, false, pause, pause));
    }

    function test_Legacy_SiloLifecycle() public {
        address pool = _legacy("siloed-1.6.0");
        _wire(pool, PoolVersions.Version.V1_6_0, FUJI);
        _wire(pool, PoolVersions.Version.V1_6_0, BASE);
        shim.requireSiloed(pool, PoolVersions.Op.SILOED_LIQUIDITY);
        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);

        ISiloedLockReleaseV16.SiloConfigUpdate[] memory adds = new ISiloedLockReleaseV16.SiloConfigUpdate[](1);
        adds[0] = ISiloedLockReleaseV16.SiloConfigUpdate({remoteChainSelector: FUJI, rebalancer: owner});
        _exec(owner, CctActions._updateSiloDesignations(pool, new uint64[](0), adds));
        assertTrue(p.isSiloed(FUJI), "fuji siloed");
        assertFalse(p.isSiloed(BASE), "base shared");

        uint256 amount = 1e8;
        _exec(owner, CctActions._provideSiloedLiquidity(pool, token, FUJI, amount));
        assertEq(p.getAvailableTokens(FUJI), amount, "silo funded");
        assertEq(p.getUnsiloedLiquidity(), 0, "shared untouched");
        assertEq(p.getAvailableTokens(BASE), 0, "base reads the shared bucket");

        // Mainnet parks the Ronin silo rebalancer at 0x1; taking it back is the first migration step.
        _exec(owner, CctActions._setSiloRebalancer(pool, FUJI, address(1)));
        vm.expectRevert();
        vm.prank(owner);
        p.withdrawSiloedLiquidity(FUJI, amount);
        _exec(owner, CctActions._setSiloRebalancer(pool, FUJI, owner));

        uint256 before = IERC20(token).balanceOf(owner);
        _exec(owner, CctActions._withdrawSiloedLiquidity(pool, FUJI, amount));
        assertEq(IERC20(token).balanceOf(owner) - before, amount, "silo drained to the rebalancer");
        assertEq(p.getAvailableTokens(FUJI), 0, "silo empty");
    }

    function test_Siloed160_RefusesLockBoxOp() public {
        address pool = _legacy("siloed-1.6.0");
        vm.expectRevert();
        shim.requireSiloed(pool, PoolVersions.Op.CONFIGURE_LOCK_BOXES);
    }

    function test_V2_LockBoxPerSilo() public {
        vm.prank(owner);
        SiloedLockReleaseTokenPool pool =
            new SiloedLockReleaseTokenPool(IERC20(token), 18, address(0), networkConfig.rmnProxy, networkConfig.router);
        _wire(address(pool), PoolVersions.Version.V2_0_0, FUJI);
        _wire(address(pool), PoolVersions.Version.V2_0_0, BASE);
        shim.requireSiloed(address(pool), PoolVersions.Op.CONFIGURE_LOCK_BOXES);
        vm.expectRevert(abi.encodeWithSelector(SiloedLockReleaseTokenPool.LockBoxNotConfigured.selector, FUJI));
        pool.getLockBox(FUJI);

        ERC20LockBox fujiBox = new ERC20LockBox(token);
        ERC20LockBox baseBox = new ERC20LockBox(token);
        address[] memory callers = new address[](1);
        callers[0] = address(pool);
        _exec(address(this), CctActions._applyAuthorizedCallerUpdates(address(fujiBox), callers, new address[](0)));
        _exec(address(this), CctActions._applyAuthorizedCallerUpdates(address(baseBox), callers, new address[](0)));

        SiloedLockReleaseTokenPool.LockBoxConfig[] memory cfg = new SiloedLockReleaseTokenPool.LockBoxConfig[](2);
        cfg[0] = SiloedLockReleaseTokenPool.LockBoxConfig({remoteChainSelector: FUJI, lockBox: address(fujiBox)});
        cfg[1] = SiloedLockReleaseTokenPool.LockBoxConfig({remoteChainSelector: BASE, lockBox: address(baseBox)});
        _exec(owner, CctActions._configureLockBoxes(address(pool), cfg));
        assertEq(address(pool.getLockBox(FUJI)), address(fujiBox), "fuji box");
        assertEq(address(pool.getLockBox(BASE)), address(baseBox), "base box");

        // Migration target: silo liquidity withdrawn from 1.6 lands in the chain's box via deposit.
        address[] memory op = new address[](1);
        op[0] = owner;
        _exec(address(this), CctActions._applyAuthorizedCallerUpdates(address(fujiBox), op, new address[](0)));
        _exec(owner, CctActions._lockboxDeposit(address(fujiBox), token, 1e8));
        assertEq(IERC20(token).balanceOf(address(fujiBox)), 1e8, "fuji box funded");
        assertEq(IERC20(token).balanceOf(address(baseBox)), 0, "base box isolated");
    }
}
