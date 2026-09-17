// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {IERC20Metadata} from "@openzeppelin/contracts@5.3.0/token/ERC20/extensions/IERC20Metadata.sol";
import {LegacyPools} from "./LegacyPools.sol";

/// @notice Deploys a released legacy pool for a staging fixture that mirrors a partner deployment. It records
///         nothing: `make adopt-token` takes the pool into the project store, which is the support check.
///
/// `kind` is one of siloed-1.6.0 | siloed-1.6.1 | burnmint-1.5.1 | burnmint-1.6.1.
///
/// Usage:
///   forge script test/fixtures/legacy/DeployLegacyPool.s.sol --sig "run(string,address)" siloed-1.6.0 <token> \
///     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account <KEYSTORE_NAME> --broadcast
contract DeployLegacyPool is Script, LegacyPools {
    function run(string memory kind, address token) external returns (address pool) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(block.chainid);
        require(config.router != address(0) && config.rmnProxy != address(0), "router/rmnProxy missing in chain config");

        uint8 decimals = IERC20Metadata(token).decimals();
        bytes memory args = abi.encode(token, decimals, new address[](0), config.rmnProxy, config.router);

        vm.startBroadcast();
        pool = _deploy(bytes.concat(_creationCode(kind), args));
        vm.stopBroadcast();

        console.log(string.concat("Legacy pool (", kind, "): ", vm.toString(pool)));
        console.log(string.concat("  router ", vm.toString(config.router), "  rmnProxy ", vm.toString(config.rmnProxy)));
    }

    function _creationCode(string memory kind) internal pure returns (bytes memory) {
        bytes[4] memory codes = _legacyPoolCreationCodes();
        bytes32 k = keccak256(bytes(kind));
        if (k == keccak256("siloed-1.6.0")) return codes[0];
        if (k == keccak256("burnmint-1.5.1")) return codes[1];
        if (k == keccak256("siloed-1.6.1")) return codes[2];
        if (k == keccak256("burnmint-1.6.1")) return codes[3];
        revert(string.concat("Unknown legacy pool kind '", kind, "'"));
    }

    function _deploy(bytes memory initCode) internal returns (address addr) {
        assembly {
            addr := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(addr != address(0), "pool deployment reverted");
    }
}
