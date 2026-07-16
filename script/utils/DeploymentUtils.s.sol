// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeploymentUtils
/// @notice Shared deployment-saving utilities used by all deploy scripts to avoid duplication.
/// Each function creates the target directory if it does not exist, writes a timestamped JSON
/// file containing the deployed contract address(es), and prints the saved path to the console.
///
/// @dev The append-only ledger lives under **`history/<category>/<selectorName>/…`**, keyed by the
/// canonical **selectorName** directory. The token, pool, and lock-box file bodies key by
/// `chainNameIdentifier` (e.g. `ETHEREUM_SEPOLIA_TOKEN`), so those callers pass BOTH the selectorName
/// (the directory) and the chainNameIdentifier (the body); the hooks file is named by symbol +
/// poolType and carries a fixed `POOL_HOOKS` body key. Each deploy writes a NEW timestamped file —
/// pure create, never rewrite. `history/` is gitignored.
library DeploymentUtils {
    /// @dev Saves a token deployment.
    /// Output: `history/tokens/{selectorName}/{timestamp}-{symbol}-Token.json`
    /// @param vm              Forge VM cheat-code interface
    /// @param selectorName    Canonical selectorName (the ledger directory, == config basename)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param symbol          Token symbol, used as the file-name prefix
    /// @param tokenAddress    Address of the deployed token contract
    function saveTokenDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        string memory symbol,
        address tokenAddress
    ) internal {
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/tokens/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique serialization handle per call: forge's serialize journal is keyed by the handle and
        // ACCUMULATES across calls in one process, so a shared handle would bleed stale keys from a prior
        // save into this artifact's body (proven for the pool handle). Keying by the address isolates it.
        string memory handle = string.concat("tokenDeployment-", vm.toString(tokenAddress));
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-Token.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat("Deployment saved: history/tokens/", selectorName, "/", timestamp, "-", symbol, "-Token.json")
        );
    }

    /// @dev Saves a burn-mint token pool deployment.
    /// Output: `history/token-pools/{selectorName}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param poolType            Pool type label used in the file name (e.g. `BurnMint`)
    function saveTokenPoolDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/token-pools/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment): a shared "poolDeployment" handle would carry a
        // stale LOCK_BOX key from a prior lock-release save into this burn-mint body.
        string memory handle = string.concat("poolDeployment-", vm.toString(tokenPoolAddress));
        vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/token-pools/",
                selectorName,
                "/",
                timestamp,
                "-",
                symbol,
                "-",
                poolType,
                "TokenPool.json"
            )
        );
    }

    /// @dev Saves a lock-release token pool deployment (includes the associated lock box address).
    /// Output: `history/token-pools/{selectorName}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param lockBox             Address of the ERC20LockBox associated with this pool
    /// @param poolType            Pool type label used in the file name (e.g. `LockRelease`)
    function saveLockReleaseTokenPoolDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        address lockBox,
        string memory poolType
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/token-pools/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment) so this lock-release body never bleeds keys
        // into (or from) a sibling pool save sharing the process.
        string memory handle = string.concat("poolDeployment-", vm.toString(tokenPoolAddress));
        vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        vm.serializeAddress(handle, "LOCK_BOX", lockBox);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/token-pools/",
                selectorName,
                "/",
                timestamp,
                "-",
                symbol,
                "-",
                poolType,
                "TokenPool.json"
            )
        );
    }

    /// @dev Saves a lock box deployment.
    /// Output: `history/lock-boxes/{selectorName}/{timestamp}-{symbol}-LockBox.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param lockBoxAddress      Address of the deployed ERC20LockBox contract
    /// @param tokenAddress        Address of the token the lock box is deployed for (used to resolve the symbol)
    function saveLockBoxDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address lockBoxAddress,
        address tokenAddress
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/lock-boxes/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment).
        string memory handle = string.concat("lockBoxDeployment-", vm.toString(lockBoxAddress));
        vm.serializeAddress(handle, "LOCK_BOX", lockBoxAddress);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-LockBox.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/lock-boxes/", selectorName, "/", timestamp, "-", symbol, "-LockBox.json"
            )
        );
    }

    /// @dev Saves an AdvancedPoolHooks deployment.
    /// Output: `history/advanced-pool-hooks/{selectorName}/{timestamp}-{symbol}-{poolType}AdvancedPoolHooks.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param symbol              Token symbol (distinguishes co-located tokens' hooks, matching the ledger)
    /// @param poolType            Pool type the hooks belong to
    /// @param hooksAddress        Address of the deployed AdvancedPoolHooks contract
    function savePoolHooksDeployment(
        Vm vm,
        string memory selectorName,
        string memory symbol,
        string memory poolType,
        address hooksAddress
    ) internal {
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/history/advanced-pool-hooks/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment) for isolation across sibling saves.
        string memory handle = string.concat("hooksDeployment-", vm.toString(hooksAddress));
        string memory deploymentJson = vm.serializeAddress(handle, "POOL_HOOKS", hooksAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory fileName = string.concat(timestamp, "-", symbol, "-", poolType, "AdvancedPoolHooks.json");
        vm.writeJson(deploymentJson, string.concat(deploymentDir, fileName));

        console.log(string.concat("Deployment saved: history/advanced-pool-hooks/", selectorName, "/", fileName));
    }

    /// @dev Resolves the token symbol by calling `symbol()` on the token contract, falling back to
    /// the TOKEN_SYMBOL environment variable, or "unknown" if neither is available.
    /// `internal` so the single-writer `DeploymentRecorder` composes the registry key from the same
    /// symbol the ledger file is named with.
    function getSymbol(Vm vm, address tokenAddress) internal view returns (string memory symbol) {
        try IERC20Metadata(tokenAddress).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = vm.envOr("TOKEN_SYMBOL", string("unknown"));
        }
    }
}
