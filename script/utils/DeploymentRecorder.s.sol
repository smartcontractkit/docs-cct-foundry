// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentUtils} from "./DeploymentUtils.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @title DeploymentRecorder
/// @notice The single writer for a deployed artifact. Each deploy script makes ONE recorder call per
/// artifact that (a) emits the detailed timestamped ledger file via `DeploymentUtils.save*` (Syed's
/// format, byte-for-byte unchanged) AND (b) upserts the address into `addresses/<chainId>.json` via
/// `RegistryWriter` (`deployments[name]` + `active[role]`). This collapses the historical
/// double-write — two adjacent, independently-maintained calls (`DeploymentUtils.save*` then
/// `RegistryWriter.record`) that wrote the same address to two stores in two formats with nothing
/// keeping them in sync — into one call, so the two stores can never drift.
///
/// @dev The registry half is context-aware (via `RegistryWriter.record`): it no-ops under `forge test`
/// and on a dry-run `forge script`, and writes only on `--broadcast`/`--resume`. The ledger half
/// (`DeploymentUtils.save*`) always writes, exactly as before. The `deployments` key is composed here
/// from the same symbol the ledger file is named with (`DeploymentUtils.getSymbol`), so the key and the
/// filename never disagree.
///
/// Keying:
/// | Artifact  | `deployments` key                        | `active` role |
/// | --------- | ---------------------------------------- | ------------- |
/// | token     | `{symbol}_Token`                         | `token`       |
/// | tokenPool | `{symbol}_{poolType}TokenPool_{version}` | `tokenPool`   |
/// | lockBox   | `{symbol}_LockBox`                        | `lockBox`     |
/// | poolHooks | `{symbol}_{poolType}_PoolHooks`          | `poolHooks`   |
library DeploymentRecorder {
    /// @notice The pinned `@chainlink/contracts-ccip` pool version. Used both to compose the versioned
    /// `tokenPool` key and as the value the deploy scripts assert against the pool's on-chain
    /// `typeAndVersion()` (a cheap check that the pinned dependency matches the recorded key).
    string internal constant POOL_VERSION = "2.0.0";

    /// @notice Records a token deployment: ledger file + `deployments[{symbol}_Token]` + `active.token`.
    function recordToken(
        Vm vm,
        uint256 chainId,
        string memory chainNameIdentifier,
        string memory symbol,
        address tokenAddress
    ) internal {
        DeploymentUtils.saveTokenDeployment(vm, chainNameIdentifier, symbol, tokenAddress);
        RegistryWriter.record(chainId, "token", tokenName(symbol), tokenAddress);
    }

    /// @notice Records a burn-mint-style token pool: ledger file +
    /// `deployments[{symbol}_{poolType}TokenPool_{version}]` + `active.tokenPool`.
    function recordTokenPool(
        Vm vm,
        uint256 chainId,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        DeploymentUtils.saveTokenPoolDeployment(vm, chainNameIdentifier, tokenPoolAddress, tokenAddress, poolType);
        string memory symbol = DeploymentUtils.getSymbol(vm, tokenAddress);
        RegistryWriter.record(chainId, "tokenPool", poolName(symbol, poolType), tokenPoolAddress);
    }

    /// @notice Records a lock-release token pool (ledger includes the lock box): ledger file +
    /// `deployments[{symbol}_{poolType}TokenPool_{version}]` + `active.tokenPool`.
    function recordTokenPool(
        Vm vm,
        uint256 chainId,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        address lockBox,
        string memory poolType
    ) internal {
        DeploymentUtils.saveLockReleaseTokenPoolDeployment(
            vm, chainNameIdentifier, tokenPoolAddress, tokenAddress, lockBox, poolType
        );
        string memory symbol = DeploymentUtils.getSymbol(vm, tokenAddress);
        RegistryWriter.record(chainId, "tokenPool", poolName(symbol, poolType), tokenPoolAddress);
    }

    /// @notice Records a lock box: ledger file + `deployments[{symbol}_LockBox]` + `active.lockBox`.
    function recordLockBox(
        Vm vm,
        uint256 chainId,
        string memory chainNameIdentifier,
        address lockBoxAddress,
        address tokenAddress
    ) internal {
        DeploymentUtils.saveLockBoxDeployment(vm, chainNameIdentifier, lockBoxAddress, tokenAddress);
        string memory symbol = DeploymentUtils.getSymbol(vm, tokenAddress);
        RegistryWriter.record(chainId, "lockBox", lockBoxName(symbol), lockBoxAddress);
    }

    /// @notice Records pool hooks: ledger file + `deployments[{symbol}_{poolType}_PoolHooks]` +
    /// `active.poolHooks`. Hooks belong to a token's pool, so the key carries the token symbol (resolved
    /// from `tokenAddress`, `address(0)` → env `TOKEN_SYMBOL` / "unknown") and the pool type.
    function recordPoolHooks(
        Vm vm,
        uint256 chainId,
        string memory chainNameIdentifier,
        address hooksAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        DeploymentUtils.savePoolHooksDeployment(vm, chainNameIdentifier, hooksAddress);
        string memory symbol = DeploymentUtils.getSymbol(vm, tokenAddress);
        RegistryWriter.record(chainId, "poolHooks", hooksName(symbol, poolType), hooksAddress);
    }

    // ── key composition (pure; the deploy scripts reuse these to key the pre-broadcast guard) ──

    function tokenName(string memory symbol) internal pure returns (string memory) {
        return string.concat(symbol, "_Token");
    }

    function poolName(string memory symbol, string memory poolType) internal pure returns (string memory) {
        return string.concat(symbol, "_", poolType, "TokenPool_", POOL_VERSION);
    }

    function lockBoxName(string memory symbol) internal pure returns (string memory) {
        return string.concat(symbol, "_LockBox");
    }

    function hooksName(string memory symbol, string memory poolType) internal pure returns (string memory) {
        return string.concat(symbol, "_", poolType, "_PoolHooks");
    }
}
