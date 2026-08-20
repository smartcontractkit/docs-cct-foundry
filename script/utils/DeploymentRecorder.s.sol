// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeploymentUtils} from "./DeploymentUtils.s.sol";
import {ForgeContext} from "../../src/base/ForgeContext.sol";
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
/// @dev BOTH halves ask `ForgeContext._sendsNothing()` - one question, one answer. They record a
/// deployment, so they write only when the run actually sends (`--broadcast`/`--resume`) and stay inert
/// under `forge test`/`coverage`/`snapshot`, on a dry run, and in an unknown context (nothing is known
/// to have been sent there either, and a ledger entry is a claim that something was). The ledger half
/// used to ask a different question - not under `forge test` - which let a dry run leave a timestamped
/// `history/` file naming an address no chain had ever seen, indistinguishable from a real deployment.
/// The `forge test` case still matters and is still covered: the fork fixtures run the real deploy
/// scripts, and an unguarded ledger write strands `history/<cat>/ethereum-testnet-sepolia/` files on
/// every test run (the CI residue gate catches it). Ledger behavior itself is tested through
/// `DeploymentUtils.save*` directly. The `deployments` key is composed here from the same symbol the
/// ledger file is named with (`DeploymentUtils._getSymbol`), so the key and the filename agree.
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
        if (!ForgeContext._sendsNothing()) {
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
        if (!ForgeContext._sendsNothing()) {
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
        if (!ForgeContext._sendsNothing()) {
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
        if (!ForgeContext._sendsNothing()) {
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
        if (!ForgeContext._sendsNothing()) {
            DeploymentUtils._savePoolHooksDeployment(vm, selectorName, symbol, poolType, hooksAddress);
        }
        RegistryWriter._record(selectorName, "poolHooks", _hooksName(symbol, poolType), hooksAddress);
    }

    // ── what the run may say about the address afterwards ──

    /// @notice Whether the `record*` call above actually wrote. The deploy scripts print a block telling
    ///         the operator the address is resolvable from now on, which is only true when the stores
    ///         were written - the same question the writes themselves ask, so the message cannot claim
    ///         one thing while the store did another.
    function _recorded() internal view returns (bool) {
        return !ForgeContext._sendsNothing();
    }

    /// @notice The post-deploy resolution block: how later scripts find this address, or why they will
    ///         not. One helper rather than a copy in each deploy script, because the copies are what let
    ///         the claim outlive the write it describes.
    /// @param envVarName The override variable for this artifact, already chain-qualified
    ///        (e.g. `ETHEREUM_SEPOLIA_TOKEN`).
    function _logResolution(Vm vm, string memory envVarName, address addr) internal view {
        if (!_recorded()) {
            _logNothingRecorded();
            return;
        }
        console.log("The address is registered in the address registry; later scripts resolve it automatically.");
        console.log("To override it for a session, set the environment variable:");
        console.log(string.concat("export ", envVarName, "=", vm.toString(addr)));
    }

    /// @notice Why the address above is not resolvable, for the scripts whose closing block is too
    ///         bespoke for `_logResolution`. Deliberately prints no copy-paste address: the value is a
    ///         simulated CREATE result, and handing it over as a variable to paste into the next command
    ///         is how a phantom address gets wired into real configuration.
    function _logNothingRecorded() internal pure {
        console.log("Nothing was recorded: this run sent nothing, so neither project/ nor history/ was written.");
        console.log("Re-run with --broadcast to deploy the contract and record its address.");
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
