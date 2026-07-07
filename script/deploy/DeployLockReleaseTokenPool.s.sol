// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol"; // Network configuration helper
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeploymentUtils} from "../utils/DeploymentUtils.s.sol";
import {DeploymentRecorder} from "../utils/DeploymentRecorder.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

contract DeployLockReleaseTokenPool is Script {
    HelperConfig public helperConfig;

    function run() external {
        // Initialize HelperConfig
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔐 Deploy Lock & Release Token Pool");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       ", "Deploy lock & release token pool"));
        console.log("========================================");
        console.log("");

        // Get deployed token address — TOKEN env var takes priority, then {CHAIN}_TOKEN
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set TOKEN or ", config.chainNameIdentifier, "_TOKEN environment variable."
            )
        );

        // Get LockBox address via the standard ladder: LOCK_BOX alias > {CHAIN}_LOCK_BOX > registry
        // active.lockBox (written automatically by DeployERC20LockBox).
        address lockBox = vm.envOr("LOCK_BOX", helperConfig.getDeployedLockBox(chainId));
        require(lockBox != address(0), "LockBox not deployed. Set LOCK_BOX or run DeployERC20LockBox first.");

        // Validate router and RMN proxy addresses
        require(config.router != address(0), "Router not defined for this network");
        require(config.rmnProxy != address(0), "RMN Proxy not defined for this network");

        // decimals() is optional in ERC20; fall back to DECIMALS env var if not present
        uint8 decimals;
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            console.log(unicode"⚠️  decimals() not found on token, falling back to DECIMALS env var");
            decimals = uint8(vm.envUint("DECIMALS"));
        }
        // POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > registry active.poolHooks. Optional (0x0 = no hooks).
        address poolHooks = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));

        console.log("Token Pool Parameters:");
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Decimals:                     ", vm.toString(decimals)));
        console.log(string.concat("  Router:                       ", vm.toString(config.router)));
        console.log(string.concat("  RMN Proxy:                    ", vm.toString(config.rmnProxy)));
        console.log(string.concat("  LockBox:                      ", vm.toString(lockBox)));
        console.log(
            string.concat(
                "  AdvancedPoolHooks:            ", poolHooks != address(0) ? vm.toString(poolHooks) : "None (0x0)"
            )
        );
        console.log("");

        // Refuse to redeploy over a live registry entry (FORCE_REDEPLOY=true overrides). Keyed on the
        // unique per-symbol/per-pool-type/per-version deployment name so a BurnMint and a LockRelease
        // pool (or an old and a new version) for the same token never collide.
        string memory symbol = DeploymentUtils.getSymbol(vm, tokenAddress);
        RegistryWriter.guard(chainId, DeploymentRecorder.poolName(symbol, "LockRelease"));

        vm.startBroadcast();

        console.log(string.concat("\n[Step 1] Deploying LockReleaseTokenPool on ", chainName));
        LockReleaseTokenPool tokenPool = new LockReleaseTokenPool(
            IERC20(tokenAddress), decimals, poolHooks, config.rmnProxy, config.router, lockBox
        );
        address tokenPoolAddress = address(tokenPool);
        console.log(string.concat("Token Pool deployed at: ", vm.toString(tokenPoolAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress));
        console.log(unicode"✅ LockReleaseTokenPool deployed successfully!");

        vm.stopBroadcast();

        // Assert the on-chain typeAndVersion matches the version composed into the registry key — a
        // cheap guard against a pinned-dependency mismatch (recording a 2.0.0 key for a stale pool).
        string memory expectedTypeAndVersion = string.concat("LockReleaseTokenPool ", DeploymentRecorder.POOL_VERSION);
        require(
            keccak256(bytes(tokenPool.typeAndVersion())) == keccak256(bytes(expectedTypeAndVersion)),
            string.concat(
                "typeAndVersion mismatch: on-chain '",
                tokenPool.typeAndVersion(),
                "' != key '",
                expectedTypeAndVersion,
                "'"
            )
        );

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deployment Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Token Pool Address: ", vm.toString(tokenPoolAddress)));
        console.log(helperConfig.getExplorerUrl(chainId, "/address/", tokenPoolAddress));
        console.log("");
        // Single writer: one call emits the detailed ledger file (with the lock box) AND records the
        // address in the registry (deployments[{symbol}_LockReleaseTokenPool_{version}] + active.tokenPool).
        DeploymentRecorder.recordTokenPool(
            vm, chainId, config.chainNameIdentifier, tokenPoolAddress, tokenAddress, lockBox, "LockRelease"
        );
        console.log("");
        console.log("The address is registered in the address registry; later scripts resolve it automatically.");
        console.log("To override it for a session, set the environment variable:");
        console.log(string.concat("export ", config.chainNameIdentifier, "_TOKEN_POOL=", vm.toString(tokenPoolAddress)));
        console.log("========================================");
        console.log("");
    }
}
