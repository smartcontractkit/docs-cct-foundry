// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeploymentUtils
/// @notice Shared deployment-saving utilities used by all deploy scripts to avoid duplication.
/// Each function creates the target directory if it does not exist, writes a timestamped JSON
/// file containing the deployed contract address(es), and prints the saved path to the console.
library DeploymentUtils {
    /// @dev Saves a token deployment.
    /// Output: `script/deployments/tokens/{chainNameIdentifier}/{timestamp}-{symbol}-Token.json`
    /// @param vm              Forge VM cheat-code interface
    /// @param chainNameIdentifier Chain identifier string (e.g. `ETHEREUM_SEPOLIA`)
    /// @param symbol          Token symbol, used as the file-name prefix
    /// @param tokenAddress    Address of the deployed token contract
    function saveTokenDeployment(Vm vm, string memory chainNameIdentifier, string memory symbol, address tokenAddress)
        internal
    {
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/script/deployments/tokens/", chainNameIdentifier, "/");
        vm.createDir(deploymentDir, true);

        string memory deploymentJson =
            vm.serializeAddress("tokenDeployment", string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-Token.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: script/deployments/tokens/",
                chainNameIdentifier,
                "/",
                timestamp,
                "-",
                symbol,
                "-Token.json"
            )
        );
    }

    /// @dev Saves a burn-mint token pool deployment.
    /// Output: `script/deployments/token-pools/{chainNameIdentifier}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param chainNameIdentifier Chain identifier string (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param poolType            Pool type label used in the file name (e.g. `BurnMint`)
    function saveTokenPoolDeployment(
        Vm vm,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/script/deployments/token-pools/", chainNameIdentifier, "/");
        vm.createDir(deploymentDir, true);

        vm.serializeAddress("poolDeployment", string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        string memory deploymentJson =
            vm.serializeAddress("poolDeployment", string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: script/deployments/token-pools/",
                chainNameIdentifier,
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
    /// Output: `script/deployments/token-pools/{chainNameIdentifier}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param chainNameIdentifier Chain identifier string (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param lockBox             Address of the ERC20LockBox associated with this pool
    /// @param poolType            Pool type label used in the file name (e.g. `LockRelease`)
    function saveLockReleaseTokenPoolDeployment(
        Vm vm,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        address lockBox,
        string memory poolType
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/script/deployments/token-pools/", chainNameIdentifier, "/");
        vm.createDir(deploymentDir, true);

        vm.serializeAddress("poolDeployment", string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        vm.serializeAddress("poolDeployment", "LOCK_BOX", lockBox);
        string memory deploymentJson =
            vm.serializeAddress("poolDeployment", string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: script/deployments/token-pools/",
                chainNameIdentifier,
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
    /// Output: `script/deployments/lock-boxes/{chainNameIdentifier}/{timestamp}-{symbol}-LockBox.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param chainNameIdentifier Chain identifier string (e.g. `ETHEREUM_SEPOLIA`)
    /// @param lockBoxAddress      Address of the deployed ERC20LockBox contract
    /// @param tokenAddress        Address of the token the lock box is deployed for (used to resolve the symbol)
    function saveLockBoxDeployment(
        Vm vm,
        string memory chainNameIdentifier,
        address lockBoxAddress,
        address tokenAddress
    ) internal {
        string memory symbol = getSymbol(vm, tokenAddress);
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/script/deployments/lock-boxes/", chainNameIdentifier, "/");
        vm.createDir(deploymentDir, true);

        vm.serializeAddress("lockBoxDeployment", "LOCK_BOX", lockBoxAddress);
        string memory deploymentJson =
            vm.serializeAddress("lockBoxDeployment", string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-LockBox.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: script/deployments/lock-boxes/",
                chainNameIdentifier,
                "/",
                timestamp,
                "-",
                symbol,
                "-LockBox.json"
            )
        );
    }

    /// @dev Saves an AdvancedPoolHooks deployment.
    /// Output: `script/deployments/advanced-pool-hooks/{chainNameIdentifier}/{timestamp}-AdvancedPoolHooks.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param chainNameIdentifier Chain identifier string (e.g. `ETHEREUM_SEPOLIA`)
    /// @param hooksAddress        Address of the deployed AdvancedPoolHooks contract
    function savePoolHooksDeployment(Vm vm, string memory chainNameIdentifier, address hooksAddress) internal {
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/script/deployments/advanced-pool-hooks/", chainNameIdentifier, "/");
        vm.createDir(deploymentDir, true);

        string memory deploymentJson = vm.serializeAddress("hooksDeployment", "POOL_HOOKS", hooksAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-AdvancedPoolHooks.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: script/deployments/advanced-pool-hooks/",
                chainNameIdentifier,
                "/",
                timestamp,
                "-AdvancedPoolHooks.json"
            )
        );
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
