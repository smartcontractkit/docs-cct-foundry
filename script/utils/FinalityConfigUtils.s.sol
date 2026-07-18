// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";

library FinalityConfigUtils {
    // Access the forge-std vm cheatcode from within a library.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Encodes an allowed-finality mode pair into the bytes4 wire value (see FinalityCodec):
    /// both set -> safe flag + block depth (either mode acceptable), one set -> that mode alone,
    /// neither -> WAIT_FOR_FINALITY (0x00000000, fast finality disabled). Full finality is always
    /// an allowed request regardless of this value; the encoding only adds faster modes.
    function encode(bool waitForSafe, uint256 blockDepth) internal pure returns (bytes4) {
        require(
            blockDepth <= FinalityCodec.MAX_BLOCK_DEPTH,
            "finality block depth must be <= FinalityCodec.MAX_BLOCK_DEPTH (65535)"
        );
        if (waitForSafe && blockDepth > 0) return FinalityCodec._encodeBlockDepthAndSafeFlag(uint16(blockDepth));
        if (waitForSafe) return FinalityCodec.WAIT_FOR_SAFE_FLAG;
        if (blockDepth > 0) return FinalityCodec._encodeBlockDepth(uint16(blockDepth));
        return FinalityCodec.WAIT_FOR_FINALITY_FLAG;
    }

    /// @notice Reads a declared finality block (`{blockDepth?, waitForSafe?}`) at `basePath` in `json`
    /// and encodes it. Absent keys default to no-depth / no-safe-flag, so an empty declared block
    /// encodes WAIT_FOR_FINALITY (declared-disabled). Callers gate on the block's presence; this
    /// helper never decides declaredness.
    function parseDeclared(string memory json, string memory basePath) internal view returns (bytes4) {
        bool waitForSafe;
        uint256 blockDepth;
        string memory safePath = string.concat(basePath, ".waitForSafe");
        string memory depthPath = string.concat(basePath, ".blockDepth");
        if (vm.keyExistsJson(json, safePath)) waitForSafe = vm.parseJsonBool(json, safePath);
        if (vm.keyExistsJson(json, depthPath)) {
            blockDepth = vm.parseJsonUint(json, depthPath);
            require(
                blockDepth <= FinalityCodec.MAX_BLOCK_DEPTH,
                string.concat(basePath, ".blockDepth must be <= FinalityCodec.MAX_BLOCK_DEPTH (65535)")
            );
        }
        return encode(waitForSafe, blockDepth);
    }

    /// @notice Returns a human-readable label for a bytes4 finality config value.
    function decodeModeLabel(bytes4 config) internal pure returns (string memory) {
        if (config == FinalityCodec.WAIT_FOR_FINALITY_FLAG) {
            return "WAIT_FOR_FINALITY (default -- disables fast finality)";
        }
        if (config == FinalityCodec.WAIT_FOR_SAFE_FLAG) {
            return "WAIT_FOR_SAFE";
        }
        uint16 depth = uint16(uint32(config & FinalityCodec.BLOCK_DEPTH_MASK));
        uint32 flags = uint32(config) >> FinalityCodec.BLOCK_DEPTH_BITS;
        if (depth > 0 && flags == 0) {
            return string.concat("BLOCK_DEPTH (", vm.toString(depth), " blocks)");
        }
        if (depth > 0 && flags == 1) {
            return string.concat("WAIT_FOR_SAFE + BLOCK_DEPTH (", vm.toString(depth), " blocks)");
        }
        return "Custom / Reserved flags";
    }

    /// @notice Logs a bytes4 finality config value with its raw encoding, mode label, and description.
    function logFinalityConfig(bytes4 config) internal pure {
        console.log(string.concat("Allowed Finality Config (raw): ", vm.toString(abi.encodePacked(config))));
        console.log("");
        if (config == FinalityCodec.WAIT_FOR_FINALITY_FLAG) {
            console.log("Mode: WAIT_FOR_FINALITY (default)");
            console.log("  Full finality is required. Fast finality transfers are disabled.");
        } else if (config == FinalityCodec.WAIT_FOR_SAFE_FLAG) {
            console.log("Mode: WAIT_FOR_SAFE");
            console.log("  Fast finality transfers wait for the `safe` head.");
        } else {
            uint16 depth = uint16(uint32(config & FinalityCodec.BLOCK_DEPTH_MASK));
            uint32 flags = uint32(config) >> FinalityCodec.BLOCK_DEPTH_BITS;
            if (depth > 0 && flags == 0) {
                console.log(string.concat("Mode: BLOCK_DEPTH (", vm.toString(depth), " blocks)"));
                console.log("  Fast finality transfers wait for the configured number of block confirmations.");
            } else if (depth > 0 && flags == 1) {
                console.log(string.concat("Mode: WAIT_FOR_SAFE + BLOCK_DEPTH (", vm.toString(depth), " blocks)"));
                console.log("  The pool accepts either the `safe` head or the configured block depth.");
            } else {
                console.log("Mode: Custom / Reserved flags");
                console.log("  See the FinalityCodec library for encoding details.");
            }
        }
    }
}
