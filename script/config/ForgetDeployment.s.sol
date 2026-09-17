// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {TolerantCall} from "../../src/utils/TolerantCall.sol";

/// @notice Removes one retired entry from `addresses.deployments` in the project store, typically the old
/// pool after a migration. Local store edit only; nothing is sent. Refuses while the entry is still in use:
///   - any `active` role points at it;
///   - a pool the TokenAdminRegistry still routes to, or that still supports a remote chain;
///   - a lock box that still holds the token.
/// The address stays in `history/` if it was ever broadcast, and is printed here.
///
/// Usage (via the Makefile):
///   make forget-deployment CHAIN=<name> NAME=<deployments key> [GROUP=<g>] [PREVIEW=1]
contract ForgetDeployment is Script {
    string internal constant CONFIG_DIR = "config/chains/";

    function run(string memory name, string memory deploymentName, bool preview) external {
        string memory path = string.concat(CONFIG_DIR, name, ".json");
        require(vm.exists(path), string.concat("no ", path));
        string memory json = vm.readFile(path);

        string memory value = RegistryWriter._readDeploymentString(name, deploymentName);
        require(
            bytes(value).length != 0,
            string.concat("no addresses.deployments.", deploymentName, " in ", ProjectStore._display(name))
        );
        string memory role = RegistryWriter._activeRoleFor(name, value);
        require(
            bytes(role).length == 0,
            string.concat(deploymentName, " is active.", role, " - it is the live artifact, not a retired one")
        );

        console.log("");
        console.log("========================================");
        console.log(unicode"🧹 Forget a retired deployment");
        console.log("========================================");
        console.log(string.concat("Store:   ", ProjectStore._display(name)));
        console.log(string.concat("Entry:   ", deploymentName, " = ", value));

        if (keccak256(bytes(vm.parseJsonString(json, ".chainFamily"))) == keccak256("evm")) {
            _createFork(json);
            address target = vm.parseAddress(value);
            string memory refusal = liveUseReason(
                deploymentName,
                target,
                RegistryWriter._read(name, "token"),
                vm.parseJsonAddress(json, ".ccip.tokenAdminRegistry")
            );
            require(bytes(refusal).length == 0, refusal);
            console.log("On-chain: not registered, no remote chains, no balance held - safe to forget.");
        } else {
            console.log("On-chain: not checked (non-EVM chain) - confirm the artifact is retired yourself.");
        }

        if (preview) {
            console.log("PREVIEW: the store is unchanged. Re-run without PREVIEW=1 to remove the entry.");
            return;
        }
        RegistryWriter._forgetDeployment(name, deploymentName);
    }

    /// @notice Why `target` is still in use, or "" when it is safe to forget. Pools: still the registered
    /// pool, or still supporting a remote chain. Lock boxes: still holding the token.
    function liveUseReason(string memory deploymentName, address target, address token, address tokenAdminRegistry)
        public
        view
        returns (string memory)
    {
        if (_contains(deploymentName, "TokenPool_")) {
            if (token != address(0) && tokenAdminRegistry.code.length > 0) {
                try TokenAdminRegistry(tokenAdminRegistry).getPool(token) returns (address registered) {
                    if (registered == target) {
                        return string.concat(
                            deploymentName,
                            " is the pool the TokenAdminRegistry routes to - SetPool to its successor first"
                        );
                    }
                } catch {}
            }
            uint256 chains = _supportedChainCount(target);
            if (chains > 0) {
                return string.concat(
                    deploymentName,
                    " still supports ",
                    vm.toString(chains),
                    " remote chain(s) - retire its lanes (RemoveChain) after the drain first"
                );
            }
        } else if (_contains(deploymentName, "_LockBox") && token != address(0) && token.code.length > 0) {
            uint256 held = IERC20(token).balanceOf(target);
            if (held > 0) {
                return string.concat(
                    deploymentName, " still holds ", vm.toString(held), " of the token - move the liquidity first"
                );
            }
        }
        return "";
    }

    /// @dev 0 for a pool that does not answer: nothing to protect on an address that is not a live pool.
    function _supportedChainCount(address pool) internal view returns (uint256) {
        if (pool.code.length == 0) return 0;
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("getSupportedChains()"));
        if (!ok || !TolerantCall._decodesAsDynamic(ret, 32)) return 0;
        return abi.decode(ret, (uint64[])).length;
    }

    function _createFork(string memory json) internal {
        string memory url = vm.envOr(vm.parseJsonString(json, ".rpcEnv"), string(""));
        require(bytes(url).length > 0, "chain RPC unset - the in-use checks read the chain");
        // forge-lint: disable-next-line(unused-return) - nothing switches back to another fork
        vm.createSelectFork(url);
        require(block.chainid == vm.parseJsonUint(json, ".chainId"), "RPC chain id does not match the config");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
