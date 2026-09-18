// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {ISiloedLockReleaseV16} from "../../../src/actions/CctActions.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {SiloedLockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/SiloedLockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";

/// @notice Reads where a SiloedLockReleaseTokenPool keeps its liquidity, per remote chain. On 1.6.x: each
///         chain's silo (or the shared bucket), rebalancer and available amount, and whether the silo
///         accounting adds up to the pool's token balance. On 2.0.0: each chain's lock box, its balance,
///         and whether the pool is an authorized caller on it.
///
/// Usage:
///   forge script script/configure/siloed/GetSiloedPoolState.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
contract GetSiloedPoolState is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        address pool = _resolvePool(chainId);

        (bool ok, PoolVersions.Version version, string memory full) = PoolVersion._tryResolve(pool);
        require(
            ok && PoolVersion._isSiloed(PoolVersion._typePrefixOf(full)),
            string.concat("Not a cataloged SiloedLockReleaseTokenPool: ", vm.toString(pool), " reports \"", full, "\".")
        );

        address token = address(TokenPool(pool).getToken());
        uint64[] memory chains = TokenPool(pool).getSupportedChains();

        console.log("");
        console.log("========================================");
        console.log(unicode"🏦 Siloed LockRelease Pool State");
        console.log("========================================");
        console.log(string.concat("Chain:        ", helperConfig.getChainName(chainId)));
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        console.log(string.concat("Token:        ", vm.toString(token)));
        console.log(string.concat("Remote chains: ", vm.toString(chains.length)));
        console.log("========================================");

        if (version < PoolVersions.Version.V2_0_0) {
            _reportSilos(pool, token, chains);
        } else {
            _reportLockBoxes(pool, token, chains);
        }
        console.log("========================================");
        console.log("");
    }

    function _reportSilos(address pool, address token, uint64[] memory chains) internal view {
        ISiloedLockReleaseV16 p = ISiloedLockReleaseV16(pool);
        uint256 unsiloed = p.getUnsiloedLiquidity();
        uint256 accounted = unsiloed;
        for (uint256 i = 0; i < chains.length; i++) {
            bool siloed = p.isSiloed(chains[i]);
            uint256 available = p.getAvailableTokens(chains[i]);
            if (siloed) accounted += available;
            console.log(
                string.concat(
                    "  ",
                    _chainLabel(chains[i]),
                    siloed ? "  SILOED  available=" : "  shared  available=",
                    vm.toString(available),
                    "  rebalancer=",
                    vm.toString(p.getChainRebalancer(chains[i]))
                )
            );
        }
        uint256 balance = IERC20(token).balanceOf(pool);
        console.log(string.concat("Shared bucket:  ", vm.toString(unsiloed)));
        console.log(string.concat("Pool balance:   ", vm.toString(balance)));
        // Silos of chains removed from the pool keep their balance but no longer show above.
        if (balance != accounted) {
            console.log(
                string.concat(
                    unicode"⚠️  Pool balance differs from shared + listed silos by ",
                    vm.toString(balance > accounted ? balance - accounted : accounted - balance),
                    " (direct transfers, or silos of removed chains)."
                )
            );
        }
    }

    function _reportLockBoxes(address pool, address token, uint64[] memory chains) internal view {
        SiloedLockReleaseTokenPool p = SiloedLockReleaseTokenPool(pool);
        SiloedLockReleaseTokenPool.LockBoxConfig[] memory configs = p.getAllLockBoxConfigs();
        for (uint256 i = 0; i < configs.length; i++) {
            address box = configs[i].lockBox;
            console.log(
                string.concat(
                    "  ",
                    _chainLabel(configs[i].remoteChainSelector),
                    "  lockBox=",
                    vm.toString(box),
                    "  balance=",
                    vm.toString(IERC20(token).balanceOf(box)),
                    _isAuthorized(box, pool) ? "  pool authorized" : unicode"  ⚠️ POOL NOT AUTHORIZED",
                    _isSupported(chains, configs[i].remoteChainSelector) ? "" : "  (chain no longer supported)"
                )
            );
        }
        for (uint256 i = 0; i < chains.length; i++) {
            if (!_hasBox(configs, chains[i])) {
                console.log(
                    string.concat(
                        unicode"  ⚠️ ",
                        _chainLabel(chains[i]),
                        " is supported but has no lock box: transfers revert"
                    )
                );
            }
        }
        console.log(string.concat("Fees held on pool: ", vm.toString(IERC20(token).balanceOf(pool))));
    }

    function _isAuthorized(address box, address pool) internal view returns (bool) {
        address[] memory callers = ERC20LockBox(box).getAllAuthorizedCallers();
        for (uint256 i = 0; i < callers.length; i++) {
            if (callers[i] == pool) return true;
        }
        return false;
    }

    function _hasBox(SiloedLockReleaseTokenPool.LockBoxConfig[] memory configs, uint64 selector)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].remoteChainSelector == selector) return true;
        }
        return false;
    }

    function _isSupported(uint64[] memory chains, uint64 selector) internal pure returns (bool) {
        for (uint256 i = 0; i < chains.length; i++) {
            if (chains[i] == selector) return true;
        }
        return false;
    }

    function _chainLabel(uint64 selector) internal view returns (string memory) {
        try helperConfig.getDestChainConfigBySelector(selector) returns (HelperConfig.NetworkConfig memory c) {
            if (bytes(c.chainNameIdentifier).length > 0) {
                return string.concat(c.chainNameIdentifier, " (", vm.toString(selector), ")");
            }
        } catch {}
        return vm.toString(selector);
    }
}
