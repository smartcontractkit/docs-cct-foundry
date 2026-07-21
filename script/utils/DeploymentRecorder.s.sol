// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DeploymentUtils} from "./DeploymentUtils.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @title DeploymentRecorder
/// @notice The single writer for a deployed artifact. Each deploy script makes ONE recorder call per
/// artifact that (a) emits the timestamped ledger file via `DeploymentUtils.save*` under
/// `history/<category>/<selectorName>/` AND (b) upserts the address into the `addresses{}` sub-store of
/// `project/<selectorName>.json` via `RegistryWriter` (`deployments[name]` + `active[role]`). Routing
/// both writes through one call keeps the two stores from drifting. Both stores key by the canonical
/// **selectorName**. The token, pool, and lock-box ledger file bodies key by `chainNameIdentifier`
/// (those calls pass both); the hooks ledger names its file by symbol + poolType and carries a fixed
/// `POOL_HOOKS` body key, so `recordPoolHooks` takes no `chainNameIdentifier`.
///
/// @dev The registry half is context-aware (via `RegistryWriter._record`): it no-ops under `forge test`
/// and on a dry-run `forge script`, and writes only on `--broadcast`/`--resume`. The ledger half
/// (`DeploymentUtils.save*`) writes on every SCRIPT run (dry-run included) but no-ops under
/// `forge test` - the fork fixtures run the real deploy scripts, and an unguarded ledger write strands
/// timestamped `history/<cat>/ethereum-testnet-sepolia/` files on every test run (the CI residue gate
/// catches it). Ledger behavior itself is tested through `DeploymentUtils.save*` directly. The `deployments` key is composed here from the same symbol
/// the ledger file is named with (`DeploymentUtils._getSymbol`), so the key and the filename agree.
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
    function _recordToken(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        string memory symbol,
        address tokenAddress
    ) internal {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            DeploymentUtils._saveTokenDeployment(vm, selectorName, chainNameIdentifier, symbol, tokenAddress);
        }
        RegistryWriter._record(selectorName, "token", _tokenName(symbol), tokenAddress);
    }

    /// @notice Records a burn-mint-style token pool: ledger file +
    /// `deployments[{symbol}_{poolType}TokenPool_{version}]` + `active.tokenPool`.
    function _recordTokenPool(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            DeploymentUtils._saveTokenPoolDeployment(
                vm, selectorName, chainNameIdentifier, tokenPoolAddress, tokenAddress, poolType
            );
        }
        string memory symbol = DeploymentUtils._getSymbol(vm, tokenAddress);
        RegistryWriter._record(selectorName, "tokenPool", _poolName(symbol, poolType), tokenPoolAddress);
    }

    /// @notice Records a lock-release token pool (ledger includes the lock box): ledger file +
    /// `deployments[{symbol}_{poolType}TokenPool_{version}]` + `active.tokenPool`.
    function _recordTokenPool(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        address lockBox,
        string memory poolType
    ) internal {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            DeploymentUtils._saveLockReleaseTokenPoolDeployment(
                vm, selectorName, chainNameIdentifier, tokenPoolAddress, tokenAddress, lockBox, poolType
            );
        }
        string memory symbol = DeploymentUtils._getSymbol(vm, tokenAddress);
        RegistryWriter._record(selectorName, "tokenPool", _poolName(symbol, poolType), tokenPoolAddress);
    }

    /// @notice Records a lock box: ledger file + `deployments[{symbol}_LockBox]` + `active.lockBox`.
    function _recordLockBox(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address lockBoxAddress,
        address tokenAddress
    ) internal {
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            DeploymentUtils._saveLockBoxDeployment(vm, selectorName, chainNameIdentifier, lockBoxAddress, tokenAddress);
        }
        string memory symbol = DeploymentUtils._getSymbol(vm, tokenAddress);
        RegistryWriter._record(selectorName, "lockBox", _lockBoxName(symbol), lockBoxAddress);
    }

    /// @notice Records pool hooks: ledger file + `deployments[{symbol}_{poolType}_PoolHooks]` +
    /// `active.poolHooks`. Hooks belong to a token's pool, so the key carries the token symbol (resolved
    /// from `tokenAddress`, `address(0)` → env `TOKEN_SYMBOL` / "unknown") and the pool type.
    function _recordPoolHooks(
        Vm vm,
        string memory selectorName,
        address hooksAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        string memory symbol = DeploymentUtils._getSymbol(vm, tokenAddress);
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            DeploymentUtils._savePoolHooksDeployment(vm, selectorName, symbol, poolType, hooksAddress);
        }
        RegistryWriter._record(selectorName, "poolHooks", _hooksName(symbol, poolType), hooksAddress);
    }

    // ── key composition (pure; the deploy scripts reuse these to key the pre-broadcast guard) ──

    function _tokenName(string memory symbol) internal pure returns (string memory) {
        return string.concat(symbol, "_Token");
    }

    function _poolName(string memory symbol, string memory poolType) internal pure returns (string memory) {
        return string.concat(symbol, "_", poolType, "TokenPool_", POOL_VERSION);
    }

    function _lockBoxName(string memory symbol) internal pure returns (string memory) {
        return string.concat(symbol, "_LockBox");
    }

    function _hooksName(string memory symbol, string memory poolType) internal pure returns (string memory) {
        return string.concat(symbol, "_", poolType, "_PoolHooks");
    }
}
