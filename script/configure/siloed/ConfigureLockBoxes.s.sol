// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {SiloedBase} from "./SiloedBase.s.sol";
import {PoolVersion} from "../../utils/PoolVersion.s.sol";
import {PoolVersions} from "../../../src/PoolVersions.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {SafeMode} from "../../../src/base/SafeMode.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {SiloedLockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/SiloedLockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";

/// @notice Maps remote chains to lock boxes on a SiloedLockReleaseTokenPool 2.0.0 (`configureLockBoxes`,
///         onlyOwner). Chains mapped to the same box share liquidity; a box per chain isolates it. An entry
///         can be overwritten but never removed. A supported chain with no box reverts every transfer.
///
/// The pool must be an authorized caller on each box (configure/authorized-callers). The pool does not
/// check it; this script refuses in EOA mode and warns in Safe mode, where the authorization may be in
/// the same batch.
///
/// Environment Variables (required):
///   LOCK_BOXES  - Comma-separated `<chain>=<lockBox>` pairs, chain as a name (AVALANCHE_FUJI) or selector
///
/// Usage:
///   LOCK_BOXES=AVALANCHE_FUJI=0xBoxA,ETHEREUM_TESTNET_SEPOLIA_BASE_1=0xBoxB \
///   forge script script/configure/siloed/ConfigureLockBoxes.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract ConfigureLockBoxes is SiloedBase {
    function run() external {
        helperConfig = new HelperConfig();
        address pool = _resolvePool(block.chainid);
        (, string memory full) = PoolVersion._requireSiloed(pool, PoolVersions.Op.CONFIGURE_LOCK_BOXES);
        address token = address(TokenPool(pool).getToken());
        bool safeMode = SafeMode._isSafeMode(_executionMode());

        SiloedLockReleaseTokenPool.LockBoxConfig[] memory configs = _parse(vm.envString("LOCK_BOXES"));
        SiloedLockReleaseTokenPool.LockBoxConfig[] memory current =
            SiloedLockReleaseTokenPool(pool).getAllLockBoxConfigs();

        console.log("");
        console.log("========================================");
        console.log(unicode"📦 Configure Lock Boxes");
        console.log("========================================");
        console.log(string.concat("Token Pool:   ", vm.toString(pool), " (", full, ")"));
        for (uint256 i = 0; i < configs.length; i++) {
            uint64 sel = configs[i].remoteChainSelector;
            address box = configs[i].lockBox;
            require(
                box != address(0) && box.code.length > 0, string.concat("No contract at lock box ", vm.toString(box))
            );
            require(
                ERC20LockBox(box).isTokenSupported(token),
                string.concat("Lock box ", vm.toString(box), " does not hold the pool token ", vm.toString(token))
            );
            for (uint256 j = 0; j < i; j++) {
                require(configs[j].remoteChainSelector != sel, string.concat("Chain listed twice: ", vm.toString(sel)));
            }
            if (!_isAuthorized(box, pool)) {
                string memory msg_ = string.concat(
                    "Pool ", vm.toString(pool), " is not an authorized caller on lock box ", vm.toString(box)
                );
                if (!safeMode) revert(string.concat(msg_, ". Authorize it first (UpdateAuthorizedCallers)."));
                console.log(string.concat(unicode"⚠️  ", msg_, "; include the authorization in the batch."));
            }
            if (!TokenPool(pool).isSupportedChain(sel)) {
                console.log(
                    string.concat(unicode"ℹ️  Chain ", vm.toString(sel), " is not supported by the pool yet.")
                );
            }
            console.log(
                string.concat(
                    "  ", vm.toString(sel), "  ", vm.toString(_currentBox(current, sel)), " -> ", vm.toString(box)
                )
            );
        }
        console.log("========================================");

        _executeCalls(CctActions._configureLockBoxes(pool, configs));
        _logOperationOutcome("configure lock boxes");
    }

    function _parse(string memory spec) internal view returns (SiloedLockReleaseTokenPool.LockBoxConfig[] memory out) {
        string[] memory pairs = vm.split(spec, ",");
        out = new SiloedLockReleaseTokenPool.LockBoxConfig[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            string[] memory kv = vm.split(vm.trim(pairs[i]), "=");
            require(kv.length == 2, string.concat("LOCK_BOXES entry must be <chain>=<lockBox>: ", pairs[i]));
            out[i] = SiloedLockReleaseTokenPool.LockBoxConfig({
                remoteChainSelector: _selectorOf(vm.trim(kv[0])), lockBox: vm.parseAddress(vm.trim(kv[1]))
            });
        }
    }

    function _currentBox(SiloedLockReleaseTokenPool.LockBoxConfig[] memory current, uint64 sel)
        internal
        pure
        returns (address)
    {
        for (uint256 i = 0; i < current.length; i++) {
            if (current[i].remoteChainSelector == sel) return current[i].lockBox;
        }
        return address(0);
    }

    function _isAuthorized(address box, address pool) internal view returns (bool) {
        address[] memory callers = ERC20LockBox(box).getAllAuthorizedCallers();
        for (uint256 i = 0; i < callers.length; i++) {
            if (callers[i] == pool) return true;
        }
        return false;
    }
}
