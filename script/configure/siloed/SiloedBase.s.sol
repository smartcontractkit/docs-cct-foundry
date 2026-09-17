// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {HelperConfig} from "../../HelperConfig.s.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/// @title SiloedBase
/// @notice Shared pool and remote-chain resolution for the SiloedLockRelease scripts.
abstract contract SiloedBase is EoaExecutor {
    HelperConfig public helperConfig;

    function _resolvePool(uint256 chainId) internal view returns (address pool) {
        pool = helperConfig.getDeployedTokenPool(chainId);
        require(
            pool != address(0),
            string.concat(
                "Token pool not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN_POOL environment variable. Alternatively, use the inline alias TOKEN_POOL=0x..."
            )
        );
    }

    /// @dev A chain name as `DEST_CHAIN` takes it (`AVALANCHE_FUJI`) or a numeric selector.
    function _selectorOf(string memory chain) internal view returns (uint64 selector) {
        (bool numeric, uint256 n) = _tryParseUint(chain);
        if (numeric) return uint64(n);
        selector = helperConfig.getDestChainConfig(chain).chainSelector;
        require(selector != 0, string.concat("Unknown chain '", chain, "': use a config/chains name or a selector."));
    }

    /// @dev Comma-separated list; empty input yields an empty array.
    function _selectorsOf(string memory csv) internal view returns (uint64[] memory selectors) {
        if (bytes(csv).length == 0) return new uint64[](0);
        string[] memory parts = vm.split(csv, ",");
        selectors = new uint64[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            selectors[i] = _selectorOf(vm.trim(parts[i]));
        }
    }

    function _tryParseUint(string memory s) internal pure returns (bool, uint256 n) {
        bytes memory b = bytes(s);
        if (b.length == 0) return (false, 0);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] < "0" || b[i] > "9") return (false, 0);
            n = n * 10 + (uint8(b[i]) - 48);
        }
        return (true, n);
    }
}
