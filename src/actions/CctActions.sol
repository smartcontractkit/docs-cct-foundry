// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts@5.3.0/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.3.0/access/IAccessControl.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/interfaces/IAdvancedPoolHooks.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {PoolVersions} from "../PoolVersions.sol";

/// @notice Minimal view of the TokenPool 1.5.0 lane setter. 1.5.0 is the one contract version whose
///         `applyChainUpdates` differs from every later version: a single-argument call whose
///         `ChainUpdate` carries an `allowed` flag (removals are `allowed: false` entries, processed
///         in array order) and ONE remote pool address. 1.5.1 and later share the modern
///         `(removes[], adds[])` shape the `applyChainUpdates` builder targets.
interface ITokenPoolV150 {
    struct ChainUpdate {
        uint64 remoteChainSelector;
        bool allowed;
        bytes remotePoolAddress;
        bytes remoteTokenAddress;
        RateLimiter.Config outboundRateLimiterConfig;
        RateLimiter.Config inboundRateLimiterConfig;
    }

    function applyChainUpdates(ChainUpdate[] calldata chains) external;
}

/// @notice Minimal view of the v1.x TokenPool rate-limiter setter (`setChainRateLimiterConfig`), which v2
///         pools replaced with `setRateLimitConfig(RateLimitConfigArgs[])`. Declared here so the action
///         layer can build the v1 setter's calldata without importing a script-side utility. The function
///         selector is identical wherever the signature is declared, so builder calldata stays canonical.
interface IRateLimiterV1 {
    function setChainRateLimiterConfig(
        uint64 remoteChainSelector,
        RateLimiter.Config memory outboundConfig,
        RateLimiter.Config memory inboundConfig
    ) external;
}

/// @notice Minimal view of the v1.x LockReleaseTokenPool liquidity surface. The ENTIRE v1.x LockRelease
///         family (1.5.0 / 1.5.1 / 1.6.1) manages liquidity ON THE POOL through a rebalancer: the owner
///         sets a rebalancer, and only the rebalancer may `provideLiquidity` (pulls tokens IN via
///         `transferFrom`, so the caller must approve first) or `withdrawLiquidity` (sends tokens OUT to
///         the caller, reverting `InsufficientLiquidity` when the pool balance is below the amount).
///         v2.0.0 removed all four functions and moved lock/release liquidity to an external `ILockBox`
///         (deposit/withdraw happen on the lockbox - see `operations/DepositToLockBox.s.sol`), so this
///         interface is NOT in the vendored 2.0.0 package and is declared here as a shim, exactly like
///         `ITokenPoolV150`. `getToken()` is shared with `TokenPool` and returns the pool's local token,
///         needed for the approve that precedes `provideLiquidity`.
interface ILockReleaseV1Liquidity {
    function getRebalancer() external view returns (address);
    function setRebalancer(address rebalancer) external;
    function provideLiquidity(uint256 amount) external;
    function withdrawLiquidity(uint256 amount) external;
    function getToken() external view returns (IERC20);
}

/// @notice Minimal view of the CCIP-admin setter (`setCCIPAdmin`). Present on `CrossChainToken`
///         (DEFAULT_ADMIN_ROLE-gated) and the `BurnMintERC20` family (admin/owner-gated); no vendored
///         interface exposes the setter (`IGetCCIPAdmin` is getter-only), so it is declared here as a
///         shim, exactly like `ITokenPoolV150`.
interface ISetCCIPAdmin {
    function setCCIPAdmin(address newAdmin) external;
}

/// @notice Minimal view of the Ownable mint/burn set on factory-model tokens (`FactoryBurnMintERC20`,
///         the wider `BurnMintERC677` family): owner-gated EnumerableSet grants - NOT OZ
///         AccessControl `grantRole`, which those tokens do not expose for mint/burn.
interface IOwnableMintBurn {
    function grantMintRole(address minter) external;
    function grantBurnRole(address burner) external;
    function revokeMintRole(address minter) external;
    function revokeBurnRole(address burner) external;
}

/// @title CctActions
/// @notice The shared action layer: every CCT write operation is defined here exactly once, as a pure
///         builder that returns `Call[]` structs (`target`, `value`, `data`) encoded with `abi.encodeCall`
///         on the real contract interfaces - never a hand-written 4-byte selector.
/// @dev Scripts stay thin wrappers: they parse inputs (env vars / JSON) exactly as before, call the
///      matching builder, and hand the result to an executor (`EoaExecutor` broadcasts it as an EOA).
///      Because an operation is one function returning `Call[]`, later execution modes (multisig batch,
///      timelock schedule/execute) can reuse the identical calldata without re-implementing any operation.
///      Every call is `value: 0` (CCT governance operations are never payable) and targets a deployed
///      contract resolved by the caller - no addresses are hardcoded inside the action layer.
library CctActions {
    /// @notice One on-chain call: the canonical action record shared by all execution modes.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev Wraps a single encoded call into a one-element `Call[]`.
    function _one(address target, bytes memory data) private pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: data});
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Registration (claim + accept the CCIP token admin)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claim the CCIP token admin via `RegistryModuleOwnerCustom.registerAdminViaOwner`.
    ///         The executing account must be the token's `owner()` (the module self-register check).
    /// @dev The owner-vs-getCCIPAdmin probe stays script-side (`ClaimAdmin` auto-detects which claim
    ///      path the token supports); the action layer carries one builder per claim path.
    function _registerAdminViaOwner(address registryModule, address token) internal pure returns (Call[] memory) {
        return _one(registryModule, abi.encodeCall(RegistryModuleOwnerCustom.registerAdminViaOwner, (token)));
    }

    /// @notice Claim the CCIP token admin via `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    ///         The executing account must be the token's `getCCIPAdmin()`.
    function _registerAdminViaGetCCIPAdmin(address registryModule, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(registryModule, abi.encodeCall(RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin, (token)));
    }

    /// @notice Claim the CCIP token admin via `RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin`.
    ///         The executing account must hold the token's OZ AccessControl `DEFAULT_ADMIN_ROLE` (the
    ///         claim path for a token that exposes neither `getCCIPAdmin()` nor `owner()`).
    function _registerAccessControlDefaultAdmin(address registryModule, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return
            _one(registryModule, abi.encodeCall(RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin, (token)));
    }

    /// @notice Accept the pending CCIP token admin role on the TokenAdminRegistry (step 2 of the claim).
    ///         The executing account must be the pending administrator.
    function _acceptAdminRole(address tokenAdminRegistry, address token) internal pure returns (Call[] memory) {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.acceptAdminRole, (token)));
    }

    /// @notice Claim (via `registerAdminViaOwner`) and accept the CCIP token admin as ONE atomic batch.
    /// @dev The claim sets the registry's pending administrator to the calling account, so an
    ///      `acceptAdminRole` executed by the same account in the same batch succeeds - the two-step
    ///      registration collapses into one submission when both calls share the executing account.
    function _registerAndAcceptAdminViaOwner(address registryModule, address tokenAdminRegistry, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return _concat(_registerAdminViaOwner(registryModule, token), _acceptAdminRole(tokenAdminRegistry, token));
    }

    /// @notice Claim (via `registerAdminViaGetCCIPAdmin`) and accept the CCIP token admin as ONE atomic
    ///         batch. Same pending-administrator reasoning as `registerAndAcceptAdminViaOwner`.
    function _registerAndAcceptAdminViaGetCCIPAdmin(address registryModule, address tokenAdminRegistry, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return
            _concat(_registerAdminViaGetCCIPAdmin(registryModule, token), _acceptAdminRole(tokenAdminRegistry, token));
    }

    /// @notice Claim (via `registerAccessControlDefaultAdmin`) and accept the CCIP token admin as ONE atomic
    ///         batch. Same pending-administrator reasoning as `registerAndAcceptAdminViaOwner`.
    function _registerAndAcceptAdminViaAccessControl(address registryModule, address tokenAdminRegistry, address token)
        internal
        pure
        returns (Call[] memory)
    {
        return
            _concat(
                _registerAccessControlDefaultAdmin(registryModule, token), _acceptAdminRole(tokenAdminRegistry, token)
            );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pool lane configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add/remove/update remote chains on a token pool via `applyChainUpdates`. This is the
    ///         lane setter for pool contract versions 1.5.1 and later, which all share this ABI.
    /// @dev Takes ALREADY-ENCODED remote pool and token bytes inside `ChainUpdate` (EVM:
    ///      `abi.encode(address)`; SVM: raw 32 bytes) so the chain-family encoding stays in
    ///      `ChainHandlers` - the action layer never interprets remote addresses.
    function _applyChainUpdates(address pool, uint64[] memory removes, TokenPool.ChainUpdate[] memory updates)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.applyChainUpdates, (removes, updates)));
    }

    /// @notice The 1.5.0-shaped lane setter (`applyChainUpdates(ChainUpdate[])`). Entries are
    ///         processed in array order, so a replacement is one call with the `allowed: false`
    ///         entry before the `allowed: true` entry for the same selector. Removal entries must
    ///         carry disabled rate-limit configs; the version supports one remote pool per chain.
    function _applyChainUpdatesV150(address pool, ITokenPoolV150.ChainUpdate[] memory updates)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(ITokenPoolV150.applyChainUpdates, (updates)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TokenAdminRegistry administration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Point a token at its pool in the TokenAdminRegistry (the registry cutover).
    ///         The executing account must be the token's registry administrator.
    function _setPool(address tokenAdminRegistry, address token, address pool) internal pure returns (Call[] memory) {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.setPool, (token, pool)));
    }

    /// @notice Transfer the registry administrator role to a new address (step 1 of two; the new
    ///         administrator must `acceptAdminRole`).
    function _transferAdminRole(address tokenAdminRegistry, address token, address newAdmin)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(tokenAdminRegistry, abi.encodeCall(TokenAdminRegistry.transferAdminRole, (token, newAdmin)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership (pool / hooks / lockbox / Ownable tokens)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Initiate an ownership transfer on any `IOwnable` contract (Chainlink `ConfirmedOwner`
    ///         and OZ `Ownable`/`Ownable2Step` share this signature). Two-step variants require the new
    ///         owner to `acceptOwnership`; plain OZ `Ownable` transfers immediately.
    function _transferOwnership(address target, address newOwner) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IOwnable.transferOwnership, (newOwner)));
    }

    /// @notice Complete a two-step ownership transfer. The executing account must be the pending owner.
    function _acceptOwnership(address target) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IOwnable.acceptOwnership, ()));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Token admin handoff (AccessControl token variants)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Begin the default-admin transfer on an `AccessControlDefaultAdminRules` token (e.g.
    ///         `CrossChainToken`). Step 1 of two; the new admin accepts after the configured delay.
    function _beginDefaultAdminTransfer(address token, address newAdmin) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IAccessControlDefaultAdminRules.beginDefaultAdminTransfer, (newAdmin)));
    }

    /// @notice Accept a pending default-admin transfer. The executing account must be the pending
    ///         default admin and the transfer delay must have elapsed.
    function _acceptDefaultAdminTransfer(address token) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer, ()));
    }

    /// @notice Grant an AccessControl role.
    function _grantRole(address target, bytes32 role, address account) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IAccessControl.grantRole, (role, account)));
    }

    /// @notice Revoke an AccessControl role.
    function _revokeRole(address target, bytes32 role, address account) internal pure returns (Call[] memory) {
        return _one(target, abi.encodeCall(IAccessControl.revokeRole, (role, account)));
    }

    /// @notice Atomically hand an AccessControl role from `oldHolder` to `newHolder` (grant first, then
    ///         revoke, in one batch) - the plain-AccessControl token admin handoff, which has no
    ///         two-step accept.
    function _handOffRole(address target, bytes32 role, address newHolder, address oldHolder)
        internal
        pure
        returns (Call[] memory)
    {
        return _concat(_grantRole(target, role, newHolder), _revokeRole(target, role, oldHolder));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Token roles (CCIP admin / factory-model mint-burn set)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the token's CCIP admin (`setCCIPAdmin`, one-step - no accept). On `CrossChainToken`
    ///         the executing account must hold `DEFAULT_ADMIN_ROLE`; other templates apply their own gate.
    function _setCCIPAdmin(address token, address newAdmin) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(ISetCCIPAdmin.setCCIPAdmin, (newAdmin)));
    }

    /// @notice Grant the mint role on a factory-model token (`grantMintRole`, onlyOwner Ownable set).
    function _grantMintRole(address token, address minter) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IOwnableMintBurn.grantMintRole, (minter)));
    }

    /// @notice Grant the burn role on a factory-model token (`grantBurnRole`, onlyOwner Ownable set).
    function _grantBurnRole(address token, address burner) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IOwnableMintBurn.grantBurnRole, (burner)));
    }

    /// @notice Revoke the mint role on a factory-model token (`revokeMintRole`, onlyOwner Ownable set).
    function _revokeMintRole(address token, address minter) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IOwnableMintBurn.revokeMintRole, (minter)));
    }

    /// @notice Revoke the burn role on a factory-model token (`revokeBurnRole`, onlyOwner Ownable set).
    function _revokeBurnRole(address token, address burner) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IOwnableMintBurn.revokeBurnRole, (burner)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rate limiting (version-detected dispatch)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice v1.x rate-limit setter: `setChainRateLimiterConfig(selector, outbound, inbound)`. v1 pools
    ///         carry a single (standard-finality) bucket per lane, so there is no fast-finality parameter.
    function _setChainRateLimiterConfig(
        address pool,
        uint64 remoteChainSelector,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) internal pure returns (Call[] memory) {
        return _one(
            pool, abi.encodeCall(IRateLimiterV1.setChainRateLimiterConfig, (remoteChainSelector, outbound, inbound))
        );
    }

    /// @notice v2.0+ rate-limit setter: `setRateLimitConfig(RateLimitConfigArgs[])`. The args carry the
    ///         `fastFinality` flag, so one call can target either the standard or the fast-finality bucket.
    function _setRateLimitConfig(address pool, TokenPool.RateLimitConfigArgs[] memory args)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.setRateLimitConfig, (args)));
    }

    /// @notice Version-dispatched rate-limit setter: routes a single-lane update to the v2 setter
    ///         (`setRateLimitConfig`) on pool versions that carry it, and to the v1 setter
    ///         (`setChainRateLimiterConfig`) on the versions that carry that one, per the
    ///         `PoolVersions` capability-range table. `version` stays a parameter (resolution from
    ///         on-chain `typeAndVersion()` is script-side, `script/utils/PoolVersion.s.sol`) so the
    ///         builder remains pure; the enum is data. `fastFinality` is ignored on v1 (v1 pools
    ///         have only the standard bucket). An unresolved (`UNKNOWN`) version refuses by name.
    function _setRateLimits(
        address pool,
        PoolVersions.Version version,
        uint64 remoteChainSelector,
        bool fastFinality,
        RateLimiter.Config memory outbound,
        RateLimiter.Config memory inbound
    ) internal pure returns (Call[] memory) {
        if (PoolVersions._isSupported(PoolVersions.Op.SET_RATE_LIMIT_CONFIG, version)) {
            TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
            args[0] = TokenPool.RateLimitConfigArgs({
                remoteChainSelector: remoteChainSelector,
                fastFinality: fastFinality,
                outboundRateLimiterConfig: outbound,
                inboundRateLimiterConfig: inbound
            });
            return _setRateLimitConfig(pool, args);
        }
        PoolVersions._requireSupports(PoolVersions.Op.SET_CHAIN_RATE_LIMITER_CONFIG, version, pool);
        return _setChainRateLimiterConfig(pool, remoteChainSelector, outbound, inbound);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Remote pools / dynamic config / finality / fee config (pool configuration)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add a remote pool address for a supported remote chain. `encodedRemotePool` is the
    ///         chain-family-encoded address (EVM: `abi.encode(address)`); the action layer passes it through.
    function _addRemotePool(address pool, uint64 remoteChainSelector, bytes memory encodedRemotePool)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.addRemotePool, (remoteChainSelector, encodedRemotePool)));
    }

    /// @notice Remove a remote pool address for a remote chain.
    function _removeRemotePool(address pool, uint64 remoteChainSelector, bytes memory encodedRemotePool)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.removeRemotePool, (remoteChainSelector, encodedRemotePool)));
    }

    /// @notice Update the pool's dynamic config (router, rateLimitAdmin, feeAdmin).
    function _setDynamicConfig(address pool, address router, address rateLimitAdmin, address feeAdmin)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.setDynamicConfig, (router, rateLimitAdmin, feeAdmin)));
    }

    /// @notice Set the pool's allowed fast-finality config (a `bytes4` FinalityCodec value). v2.0+ only.
    function _setAllowedFinalityConfig(address pool, bytes4 finalityConfig) internal pure returns (Call[] memory) {
        return _one(pool, abi.encodeCall(TokenPool.setAllowedFinalityConfig, (finalityConfig)));
    }

    /// @notice Apply per-lane token-transfer fee-config updates (add/update `feeConfigArgs`, disable
    ///         `removeSelectors`). v2.0+ only.
    function _applyTokenTransferFeeConfigUpdates(
        address pool,
        TokenPool.TokenTransferFeeConfigArgs[] memory feeConfigArgs,
        uint64[] memory removeSelectors
    ) internal pure returns (Call[] memory) {
        return _one(
            pool, abi.encodeCall(TokenPool.applyTokenTransferFeeConfigUpdates, (feeConfigArgs, removeSelectors))
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hooks / access control (allowlist, authorized callers)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Point a v2 pool at a new `AdvancedPoolHooks` contract.
    function _updateAdvancedPoolHooks(address pool, address newHook) internal pure returns (Call[] memory) {
        return _one(pool, abi.encodeCall(TokenPool.updateAdvancedPoolHooks, (IAdvancedPoolHooks(newHook))));
    }

    /// @notice Apply per-lane CCV (Cross-Chain Verifier) config updates on an `AdvancedPoolHooks` (v2).
    /// @dev `applyCCVConfigUpdates` FULLY REPLACES each chain's stored entry, so the caller must pass the
    ///      full four-array shape for every lane it touches (the setter script reads the current on-chain
    ///      config and carries undeclared arrays through unchanged). Targets the hooks contract, which is
    ///      Ownable with its OWN owner (resolved script-side); the executing account must be that owner.
    function _applyCCVConfigUpdates(address hooks, AdvancedPoolHooks.CCVConfigArg[] memory args)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(hooks, abi.encodeCall(AdvancedPoolHooks.applyCCVConfigUpdates, (args)));
    }

    /// @notice Set the pool-global additional-CCV threshold amount on an `AdvancedPoolHooks` (v2). A single
    ///         value (not per-lane): 0 disables the threshold so no lane's `threshold*CCVs` are required.
    /// @dev Targets the hooks contract; the executing account must be the hooks owner.
    function _setThresholdAmount(address hooks, uint256 amount) internal pure returns (Call[] memory) {
        return _one(hooks, abi.encodeCall(AdvancedPoolHooks.setThresholdAmount, (amount)));
    }

    /// @notice Apply allowlist updates (`removes`, `adds`) on an `AdvancedPoolHooks` (v2) or a v1 pool -
    ///         both expose the identical `applyAllowListUpdates(address[],address[])` selector.
    /// @dev IMMUTABILITY TRAP: on `AdvancedPoolHooks`, `allowlistEnabled` is fixed at deploy time from
    ///      whether the INITIAL allowlist was non-empty. If the hooks were deployed with an empty allowlist,
    ///      allowlisting is permanently disabled and this call reverts `AllowListNotEnabled()` - enabling
    ///      allowlisting later requires deploying a NEW hooks contract with a non-empty initial allowlist.
    function _applyAllowListUpdates(address target, address[] memory removes, address[] memory adds)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(target, abi.encodeCall(AdvancedPoolHooks.applyAllowListUpdates, (removes, adds)));
    }

    /// @notice Apply authorized-caller updates on any `AuthorizedCallers` contract - the shared base of
    ///         both `AdvancedPoolHooks` and `ERC20LockBox`, so one builder serves both variants.
    function _applyAuthorizedCallerUpdates(address target, address[] memory adds, address[] memory removes)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(
            target,
            abi.encodeCall(
                AuthorizedCallers.applyAuthorizedCallerUpdates,
                (AuthorizedCallers.AuthorizedCallerArgs({addedCallers: adds, removedCallers: removes}))
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operations (mint / lockbox deposit-withdraw / fee-token withdrawal / approve)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Mint `amount` of a burn/mint token to `to`. The executing account must hold the mint role.
    function _mint(address token, address to, uint256 amount) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IBurnMintERC20.mint, (to, amount)));
    }

    /// @notice ERC20 `approve(spender, amount)` - the allowance step `DepositToLockBox` needs before a
    ///         lockbox deposit pulls the tokens.
    function _approve(address token, address spender, uint256 amount) internal pure returns (Call[] memory) {
        return _one(token, abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    /// @notice Deposit `amount` of `token` into an `ERC20LockBox` as ONE batch: `approve(lockbox, amount)`
    ///         on the token, then `deposit(token, 0, amount)` on the lockbox (the unused remoteChainSelector
    ///         param is 0 per v2.0 semantics). The executing account must be an authorized lockbox caller.
    function _lockboxDeposit(address lockbox, address token, uint256 amount) internal pure returns (Call[] memory) {
        return _concat(
            _approve(token, lockbox, amount),
            _one(lockbox, abi.encodeCall(ERC20LockBox.deposit, (token, uint64(0), amount)))
        );
    }

    /// @notice Withdraw `amount` of `token` from an `ERC20LockBox` to `recipient` (`remoteChainSelector`
    ///         param is 0, unused). The executing account must be an authorized lockbox caller.
    function _lockboxWithdraw(address lockbox, address token, uint256 amount, address recipient)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(lockbox, abi.encodeCall(ERC20LockBox.withdraw, (token, uint64(0), amount, recipient)));
    }

    /// @notice Withdraw accrued fee-token balances from a v2 pool to `recipient`. Owner/feeAdmin gated.
    function _withdrawFeeTokens(address pool, address[] memory feeTokens, address recipient)
        internal
        pure
        returns (Call[] memory)
    {
        return _one(pool, abi.encodeCall(TokenPool.withdrawFeeTokens, (feeTokens, recipient)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LockRelease v1.x liquidity management (rebalancer model; removed in 2.0.0)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the rebalancer on a v1.x LockRelease pool (`setRebalancer`, onlyOwner). The rebalancer
    ///         is the one account allowed to `provideLiquidity` / `withdrawLiquidity`. Removed in 2.0.0,
    ///         where liquidity moved to the external lock box; gate with the type+version fence.
    function _setRebalancer(address pool, address rebalancer) internal pure returns (Call[] memory) {
        return _one(pool, abi.encodeCall(ILockReleaseV1Liquidity.setRebalancer, (rebalancer)));
    }

    /// @notice Provide `amount` of liquidity to a v1.x LockRelease pool (`provideLiquidity`). The pool
    ///         pulls the tokens via `transferFrom`, so the caller must `approve(pool, amount)` first, and
    ///         the caller must be the pool's rebalancer. Removed in 2.0.0.
    function _provideLiquidity(address pool, uint256 amount) internal pure returns (Call[] memory) {
        return _one(pool, abi.encodeCall(ILockReleaseV1Liquidity.provideLiquidity, (amount)));
    }

    /// @notice Withdraw `amount` of liquidity from a v1.x LockRelease pool (`withdrawLiquidity`). Tokens
    ///         transfer OUT to the caller (the rebalancer); the pool reverts `InsufficientLiquidity` when
    ///         its balance is below `amount`. Removed in 2.0.0.
    function _withdrawLiquidity(address pool, uint256 amount) internal pure returns (Call[] memory) {
        return _one(pool, abi.encodeCall(ILockReleaseV1Liquidity.withdrawLiquidity, (amount)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Composition
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Flatten two `Call[]`s into one batch (atomic execution set).
    function _concat(Call[] memory a, Call[] memory b) internal pure returns (Call[] memory out) {
        out = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 j = 0; j < b.length; j++) {
            out[a.length + j] = b[j];
        }
    }
}
