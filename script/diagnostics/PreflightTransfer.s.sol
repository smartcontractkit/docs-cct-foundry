// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {IPoolV1} from "@chainlink/contracts-ccip/contracts/interfaces/IPool.sol";
import {Router} from "@chainlink/contracts-ccip/contracts/Router.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";

import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @dev Minimal accessor for a token pool's bound token, common to every pool version.
interface IPoolToken {
    function getToken() external view returns (address);
}

/// @notice Preflights a token transfer before any real send by simulating both pool legs against live
///         chain state: the source pool's `lockOrBurn`, then the destination pool's `releaseOrMint` fed
///         the exact `destPoolData` the source leg produced. If either leg reverts, the transfer would
///         strand, so the preflight fails here with the decoded reason instead of on-chain.
///
///         Neither full `ccipSend` nor the destination `execute()` can be simulated before sending (they
///         are proof-gated: a merkle commit on v1.x, verifier attestations on v2.0). The pool legs can be:
///         `lockOrBurn` gates only on `msg.sender` being a registered OnRamp for the destination chain,
///         and `releaseOrMint` on a registered OffRamp for the source chain. This script satisfies both by
///         pranking the OnRamp / OffRamp resolved from the two Routers, exactly as production does. Every
///         `Pool.LockOrBurnInV1` and `Pool.ReleaseOrMintInV1` field is known before sending.
///
///         Version handling mirrors the ramps' own ERC165 dispatch: each pool is probed independently for
///         IPoolV2 (2-arg release / 3-arg lock, v2.0) or CCIP_POOL_V1 (1-arg, v1.5.0 through v1.6.x), so
///         one script covers every pool version and mixed-version lanes. The two simulations exercise the
///         full path plus both pools' validation (source: OnRamp allowed, allowlist, outbound rate limit,
///         burn/lock authority; destination: source chain allowed, source-pool wiring, RMN curse, inbound
///         rate limit, mint/release authority, liquidity).
///
///         Inputs: SOURCE_CHAIN, DEST_CHAIN (config/chains selectorNames), AMOUNT (wei), RECEIVER. The
///         routers and chain selectors resolve from each chain config, the pools from the project store
///         (SOURCE_POOL / DEST_POOL override); the two RPC URLs (SOURCE_RPC_URL / DEST_RPC_URL) are set by
///         the `make preflight` recipe from each chain's rpcEnv. Optional: ORIGINAL_SENDER (default
///         RECEIVER), REQUESTED_FINALITY (bytes4, IPoolV2 only; pass it in the HIGH 4 bytes of the 32-byte
///         word, e.g. `0x0000000100000000000000000000000000000000000000000000000000000000`, to select the
///         fast-finality inbound bucket), TOKEN_ARGS (bytes, IPoolV2 lock only).
///
/// Usage:
///   make preflight SOURCE_CHAIN=ethereum-testnet-sepolia DEST_CHAIN=avalanche-fuji AMOUNT=10000 RECEIVER=0xYou
///   # raw forge (the make recipe sets the two RPC URLs from each chain's rpcEnv):
///   SOURCE_CHAIN=ethereum-testnet-sepolia DEST_CHAIN=avalanche-fuji SOURCE_RPC_URL=$SEP DEST_RPC_URL=$FUJI \
///     AMOUNT=10000 RECEIVER=0xYou forge script script/diagnostics/PreflightTransfer.s.sol
contract PreflightTransfer is Script, StdCheats {
    /// @dev Which release/lock interface a pool answered ERC165 for.
    enum PoolIface {
        None,
        V1,
        V2
    }

    /// @dev All preflight inputs, read once so `run` stays under the stack limit.
    struct Ctx {
        string sourceRpc;
        string destRpc;
        address sourceRouter;
        address destRouter;
        address sourcePool;
        address destPool;
        uint64 sourceSelector;
        uint64 destSelector;
        uint256 amount;
        address receiver;
        address originalSender;
        bytes4 requestedFinality;
        bytes tokenArgs;
    }

    function run() external {
        // Resolve router + selector from each chain config, and the pools from the project store, so the
        // caller passes chain names (like every other target), not raw routers/selectors/pools. SOURCE_POOL
        // / DEST_POOL override the store; the two RPC URLs are set by the `make preflight` recipe from each
        // chain's rpcEnv.
        string memory sourceChain = vm.envString("SOURCE_CHAIN");
        string memory destChain = vm.envString("DEST_CHAIN");
        ChainConfig.Chain memory srcCfg = ChainConfig._load(sourceChain);
        ChainConfig.Chain memory dstCfg = ChainConfig._load(destChain);
        address receiver = vm.envAddress("RECEIVER");

        Ctx memory ctx = Ctx({
            sourceRpc: vm.envString("SOURCE_RPC_URL"),
            destRpc: vm.envString("DEST_RPC_URL"),
            sourceRouter: srcCfg.router,
            destRouter: dstCfg.router,
            sourcePool: vm.envOr("SOURCE_POOL", RegistryWriter._read(sourceChain, "tokenPool")),
            destPool: vm.envOr("DEST_POOL", RegistryWriter._read(destChain, "tokenPool")),
            sourceSelector: srcCfg.chainSelector,
            destSelector: dstCfg.chainSelector,
            amount: vm.envUint("AMOUNT"),
            receiver: receiver,
            originalSender: vm.envOr("ORIGINAL_SENDER", receiver),
            requestedFinality: bytes4(vm.envOr("REQUESTED_FINALITY", bytes32(0))),
            tokenArgs: vm.envOr("TOKEN_ARGS", bytes(""))
        });

        require(
            ctx.sourcePool != address(0),
            "source pool not in the store: deploy or adopt it (make deploy-pool / make adopt-token) or pass SOURCE_POOL"
        );
        require(ctx.destPool != address(0), "destination pool not in the store: deploy or adopt it, or pass DEST_POOL");

        console.log(unicode"🛫 Preflight token transfer");
        console.log("=========================================");
        console.log(string.concat("Source pool:   ", vm.toString(ctx.sourcePool)));
        console.log(string.concat("Dest pool:     ", vm.toString(ctx.destPool)));
        console.log(string.concat("Amount:        ", vm.toString(ctx.amount)));
        console.log(string.concat("Receiver:      ", vm.toString(ctx.receiver)));

        (bytes memory destPoolData, uint256 releaseAmount) = _simulateLockOrBurn(ctx);
        _simulateReleaseOrMint(ctx, destPoolData, releaseAmount);
    }

    /// @dev Forks the source chain and simulates the source pool's `lockOrBurn` as the registered OnRamp,
    ///      returning the pool's `destPoolData` and the effective amount the destination will receive (for
    ///      an IPoolV2 pool the fee/rescale-adjusted `destTokenAmount` the lock leg returns, so a per-lane
    ///      transfer fee is reflected; for a v1 pool the amount is unchanged). Funds the pool with `amount`
    ///      first so a burn pool has a balance to burn (production pre-transfers it through the Router).
    ///      Reverts NO-GO on any revert.
    function _simulateLockOrBurn(Ctx memory ctx) internal returns (bytes memory destPoolData, uint256 releaseAmount) {
        vm.createSelectFork(ctx.sourceRpc);
        console.log("-----------------------------------------");
        console.log("Step 1: source lockOrBurn");

        address onRamp = Router(ctx.sourceRouter).getOnRamp(ctx.destSelector);
        if (onRamp == address(0)) {
            _noGo("source Router has no OnRamp for the destination selector (lane not wired on the source side)");
        }
        address sourceToken = IPoolToken(ctx.sourcePool).getToken();
        PoolIface iface = _detect(ctx.sourcePool);
        if (iface == PoolIface.None) _noGo("source pool answers neither IPoolV2 nor CCIP_POOL_V1 (not a CCIP pool)");

        Pool.LockOrBurnInV1 memory input = Pool.LockOrBurnInV1({
            receiver: abi.encode(ctx.receiver),
            remoteChainSelector: ctx.destSelector,
            originalSender: ctx.originalSender,
            amount: ctx.amount,
            localToken: sourceToken
        });

        deal(sourceToken, ctx.sourcePool, ctx.amount);
        releaseAmount = ctx.amount;

        if (iface == PoolIface.V2) {
            vm.prank(onRamp);
            try IPoolV2(ctx.sourcePool).lockOrBurn(input, ctx.requestedFinality, ctx.tokenArgs) returns (
                Pool.LockOrBurnOutV1 memory out, uint256 destTokenAmount
            ) {
                destPoolData = out.destPoolData;
                releaseAmount = destTokenAmount;
            } catch (bytes memory reason) {
                _noGoRevert("source lockOrBurn", ctx.sourcePool, sourceToken, reason);
            }
        } else {
            vm.prank(onRamp);
            try IPoolV1(ctx.sourcePool).lockOrBurn(input) returns (Pool.LockOrBurnOutV1 memory out) {
                destPoolData = out.destPoolData;
            } catch (bytes memory reason) {
                _noGoRevert("source lockOrBurn", ctx.sourcePool, sourceToken, reason);
            }
        }

        console.log(string.concat("  OnRamp:      ", vm.toString(onRamp)));
        console.log(string.concat("  interface:   ", iface == PoolIface.V2 ? "IPoolV2" : "CCIP_POOL_V1"));
        console.log(unicode"  ✅ source pool would lock/burn; destPoolData captured.");
    }

    /// @dev Forks the destination chain and simulates the destination pool's `releaseOrMint` as the
    ///      registered OffRamp, passing the source leg's `destPoolData` as `sourcePoolData`. GO on success,
    ///      NO-GO (revert) on any revert.
    function _simulateReleaseOrMint(Ctx memory ctx, bytes memory destPoolData, uint256 releaseAmount) internal {
        vm.createSelectFork(ctx.destRpc);
        console.log("-----------------------------------------");
        console.log("Step 2: destination releaseOrMint");

        address offRamp = _resolveOffRamp(ctx.destRouter, ctx.sourceSelector);
        if (offRamp == address(0)) {
            _noGo("destination Router has no OffRamp for the source selector (lane not wired on the destination side)");
        }
        address localToken = IPoolToken(ctx.destPool).getToken();
        PoolIface iface = _detect(ctx.destPool);
        if (iface == PoolIface.None) {
            _noGo("destination pool answers neither IPoolV2 nor CCIP_POOL_V1 (not a CCIP pool)");
        }

        Pool.ReleaseOrMintInV1 memory input = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(ctx.originalSender),
            remoteChainSelector: ctx.sourceSelector,
            receiver: ctx.receiver,
            sourceDenominatedAmount: releaseAmount,
            localToken: localToken,
            sourcePoolAddress: abi.encode(ctx.sourcePool),
            sourcePoolData: destPoolData,
            offchainTokenData: bytes("")
        });

        console.log(string.concat("  OffRamp:     ", vm.toString(offRamp)));
        console.log(string.concat("  interface:   ", iface == PoolIface.V2 ? "IPoolV2" : "CCIP_POOL_V1"));

        if (iface == PoolIface.V2) {
            vm.prank(offRamp);
            try IPoolV2(ctx.destPool).releaseOrMint(input, ctx.requestedFinality) returns (
                Pool.ReleaseOrMintOutV1 memory out
            ) {
                _go(out.destinationAmount);
            } catch (bytes memory reason) {
                _noGoRevert("destination releaseOrMint", ctx.destPool, localToken, reason);
            }
        } else {
            vm.prank(offRamp);
            try IPoolV1(ctx.destPool).releaseOrMint(input) returns (Pool.ReleaseOrMintOutV1 memory out) {
                _go(out.destinationAmount);
            } catch (bytes memory reason) {
                _noGoRevert("destination releaseOrMint", ctx.destPool, localToken, reason);
            }
        }
    }

    /// @dev Resolves the OffRamp registered for `sourceSelector`, the same scan the OffRamp lookup uses.
    function _resolveOffRamp(address router, uint64 sourceSelector) internal view returns (address) {
        Router.OffRamp[] memory offRamps = Router(router).getOffRamps();
        for (uint256 i = 0; i < offRamps.length; ++i) {
            if (offRamps[i].sourceChainSelector == sourceSelector) return offRamps[i].offRamp;
        }
        return address(0);
    }

    /// @dev Dispatches off the pool's own ERC165 answer, preferring IPoolV2 as the ramps do.
    function _detect(address pool) internal view returns (PoolIface) {
        if (_supports(pool, type(IPoolV2).interfaceId)) return PoolIface.V2;
        if (_supports(pool, Pool.CCIP_POOL_V1)) return PoolIface.V1;
        return PoolIface.None;
    }

    function _supports(address pool, bytes4 interfaceId) internal view returns (bool) {
        try IERC165(pool).supportsInterface(interfaceId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _go(uint256 destinationAmount) internal pure {
        console.log("=========================================");
        console.log(unicode"✅ GO: both pool legs simulate cleanly; this transfer would execute.");
        console.log(string.concat("   destinationAmount (local decimals): ", vm.toString(destinationAmount)));
    }

    function _noGo(string memory why) internal pure {
        console.log("=========================================");
        console.log(unicode"❌ NO-GO: this transfer would strand. Fix the cause, then re-preflight.");
        console.log(string.concat("   reason: ", why));
        revert("preflight NO-GO (see reason above)");
    }

    function _noGoRevert(string memory leg, address pool, address token, bytes memory reason) internal pure {
        console.log("=========================================");
        console.log(unicode"❌ NO-GO: this transfer would strand. Fix the cause, then re-preflight.");
        console.log(string.concat("   ", leg, " reverted: ", _describeRevert(reason)));
        console.log(string.concat("   pool:  ", vm.toString(pool)));
        console.log(string.concat("   token: ", vm.toString(token)));
        console.log(string.concat("   raw:   ", vm.toString(reason)));
        console.log(
            "   for the exact contract that reverted (pool / token / lockbox / rate limiter), re-run with -vvvv"
        );
        revert("preflight NO-GO (pool leg reverts; see reason above)");
    }

    /// @dev Best-effort human reason. Decodes a standard `Error(string)` fully; names the pool / rate-limit
    ///      errors whose selectors are verified against chainlink-ccip; otherwise returns the raw 4-byte
    ///      selector to decode against the CCIP ABI (for example with `ccip-cli parse`).
    function _describeRevert(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "revert without data";
        bytes4 selector = bytes4(reason);
        if (selector == 0x08c379a0) return string.concat("Error(\"", abi.decode(_slice4(reason), (string)), "\")");
        if (selector == 0x24eb47e5) {
            return "InvalidSourcePoolAddress (source pool is not the dest pool's registered remote for this lane)";
        }
        if (selector == 0x728fe07b) {
            return "CallerIsNotARampOnRouter (the resolved ramp is not registered for this pool: the pool is wired to a different Router than the chain config, or the lane is not set up)";
        }
        if (selector == 0x1a76572a) return "TokenMaxCapacityExceeded (inbound rate limit: amount over capacity)";
        if (selector == 0xd0c8d23a) return "TokenRateLimitReached (inbound rate limit: over the current bucket)";
        if (selector == 0xe2517d3f) return "AccessControlUnauthorizedAccount (pool lacks the token's mint/burn role)";
        if (selector == 0xe2c8c9d5) return "SenderNotMinter (ERC677 pool is not a minter on the token)";
        if (selector == 0xe450d38c) return "ERC20InsufficientBalance (liquidity short)";
        if (selector == 0xcf479181) {
            return "ERC20LockBox.InsufficientBalance (LockRelease lockbox has too little liquidity)";
        }
        if (selector == 0xa17e11d5) return "InsufficientLiquidity (LockRelease pool has too little liquidity)";
        if (selector == 0x5551f198) return "InsufficientLockboxBalance (LockRelease lockbox pool short)";
        return string.concat("custom error, selector ", vm.toString(selector), " (decode against the CCIP ABI)");
    }

    /// @dev Returns `reason` without its leading 4-byte selector, for decoding the error arguments.
    function _slice4(bytes memory reason) internal pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i = 4; i < reason.length; ++i) {
            out[i - 4] = reason[i];
        }
    }
}
