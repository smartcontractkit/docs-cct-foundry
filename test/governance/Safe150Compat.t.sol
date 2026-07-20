// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {ISafe, ISafeProxyFactory} from "../../src/base/ISafe.sol";
import {SafeMode} from "../../src/base/SafeMode.sol";
import {SafeTxHash} from "../../src/base/SafeTxHash.sol";

/// @notice Forward-compatibility proof: the Safe execution mode works unchanged against a Safe
///         deployed from the canonical v1.5.0 stack. The repo's default stays v1.4.1 (the version
///         the Safe{Wallet} UI deploys, with the complete cross-chain canonical rollout - as of
///         2026-07-10 the v1.5.0 SafeL2 singleton is NOT yet deployed on e.g. Avalanche Fuji, so
///         1.4.1 remains the only stack that mirrors a fleet address everywhere). What this suite
///         pins: the `safeTxHash` math (EIP-712 domain and SafeTx typehash, frozen since 1.3.0),
///         the `execTransaction` ABI, and the MultiSend batching all hold on 1.5.0, so adopting it
///         later is a constants change (`SafeCanonical`), not a redesign.
/// @dev v1.5.0 canonical addresses from safe-global/safe-deployments v1.5.0 (verified on-chain on
///      Ethereum Sepolia before pinning here).
contract Safe150CompatForkTest is BaseForkTest {
    uint256 internal constant OWNER1_KEY = 0xA11CE;
    uint256 internal constant OWNER2_KEY = 0xB0B;
    uint256 internal constant OWNER3_KEY = 0xC0FFEE;

    uint64 internal constant EVM_SELECTOR = 8236463271206331221; // Mantle Sepolia
    address internal constant EVM_REMOTE_POOL = address(0x1111111111111111111111111111111111111111);
    address internal constant EVM_REMOTE_TOKEN = address(0x2222222222222222222222222222222222222222);

    // Canonical v1.5.0 stack (Ethereum Sepolia; safe-deployments v1.5.0).
    address internal constant SAFE_150_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address internal constant SAFE_150_L2_SINGLETON = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
    address internal constant SAFE_150_FALLBACK_HANDLER = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4;

    address internal token;
    address internal pool;
    address internal deployer;
    ISafe internal safe150;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        deployer = _scriptBroadcaster();

        // Deploy a 2-of-3 Safe from the canonical v1.5.0 stack (same owners as the 1.4.1 suites).
        require(SAFE_150_PROXY_FACTORY.code.length > 0, "v1.5.0 factory missing on this fork");
        require(SAFE_150_L2_SINGLETON.code.length > 0, "v1.5.0 SafeL2 singleton missing on this fork");
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(OWNER1_KEY);
        owners[1] = vm.addr(OWNER2_KEY);
        owners[2] = vm.addr(OWNER3_KEY);
        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (owners, 2, address(0), "", SAFE_150_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe150 = ISafe(
            ISafeProxyFactory(SAFE_150_PROXY_FACTORY).createProxyWithNonce(SAFE_150_L2_SINGLETON, initializer, 0)
        );
        assertEq(safe150.getThreshold(), 2, "1.5.0 Safe threshold");

        // The signer keys SafeMode._execDirect reads (same values as the 1.4.1 suites - no env race).
        vm.setEnv("SAFE_SIGNER_KEYS", string.concat(vm.toString(OWNER1_KEY), ",", vm.toString(OWNER2_KEY)));
    }

    /// @dev The hash math is version-stable: our local EIP-712 recompute equals the 1.5.0 Safe's
    ///      own `getTransactionHash`, under fuzzing.
    function testFuzz_SafeTxHash_MatchesOnChain_150(
        address to,
        uint256 value,
        bytes memory data,
        bool delegateCall,
        uint256 nonce
    ) public view {
        SafeTxHash.SafeTx memory t = SafeTxHash.SafeTx({
            to: to,
            value: value,
            data: data,
            operation: delegateCall ? 1 : 0,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            nonce: nonce
        });
        assertEq(
            SafeTxHash._compute(block.chainid, address(safe150), t),
            safe150.getTransactionHash(t.to, t.value, t.data, t.operation, 0, 0, 0, address(0), address(0), nonce),
            "local safeTxHash recompute must equal a v1.5.0 Safe's getTransactionHash"
        );
    }

    /// @dev The full Mode B ceremony runs unchanged against a 1.5.0 Safe: single-call ownership
    ///      accept, then a BATCHED (MultiSendCallOnly delegatecall) two-call rate-limit change -
    ///      also proving the canonical 1.4.1 MultiSendCallOnly composes with a 1.5.0 Safe.
    function test_ModeB_Ceremony_On150Safe_SingleAndBatched() public {
        // Lane + handoff.
        (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) = _laneInput();
        _exec(deployer, CctActions._applyChainUpdates(pool, removes, updates));
        vm.prank(deployer);
        TokenPool(pool).transferOwnership(address(safe150));

        // Single-call Safe tx.
        uint256 nonceBefore = safe150.nonce();
        SafeMode._execDirect(safe150, CctActions._acceptOwnership(pool));
        assertEq(TokenPool(pool).owner(), address(safe150), "1.5.0 Safe must own the pool");

        // Batched meta-tx: two rate-limit updates as ONE MultiSend delegatecall.
        CctActions.Call[] memory batched =
            CctActions._concat(_rateLimitOp(200e18, 0.2e18), _rateLimitOp(300e18, 0.3e18));
        SafeMode._execDirect(safe150, batched);

        assertEq(safe150.nonce(), nonceBefore + 2, "two ceremonies must consume exactly two nonces");
        (RateLimiter.TokenBucket memory outbound,) = TokenPool(pool).getCurrentRateLimiterState(EVM_SELECTOR, false);
        assertEq(outbound.capacity, 300e18, "the batch's last call must have landed");
    }

    function _rateLimitOp(uint128 capacity, uint128 rate) internal view returns (CctActions.Call[] memory) {
        return CctActions._setRateLimits(
            pool,
            PoolVersions.Version.V2_0_0,
            EVM_SELECTOR,
            false,
            RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate}),
            RateLimiter.Config({isEnabled: true, capacity: capacity / 2, rate: rate / 2})
        );
    }

    function _laneInput() internal pure returns (uint64[] memory removes, TokenPool.ChainUpdate[] memory updates) {
        removes = new uint64[](0);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(EVM_REMOTE_POOL);
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: EVM_SELECTOR,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(EVM_REMOTE_TOKEN),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000e18, rate: 0.1e18}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
    }
}
