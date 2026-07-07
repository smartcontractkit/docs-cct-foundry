// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IConfigSource} from "./IConfigSource.sol";

/// @title CcipApiSource
/// @notice CCIP REST API v2 implementation of the config-sync seam — fetches the ACTIVE CCIP
/// infrastructure addresses from `https://api.ccip.chain.link/v2`. Foundry cannot HTTP-GET
/// directly, so the fetch + `isActive` selection is delegated via `vm.tryFfi` to
/// `script/config/ccip-config-source.sh` (curl + jq), which returns the normalized flat JSON
/// this seam expects. Requires the `sync` foundry profile (`ffi = true`).
/// @dev The v2 flow is two-step: `GET /chains?environment=testnet` lists chains (identity metadata,
/// used by `script/config/sync-discover.sh` and `SyncCcipConfig.init`), and `GET /chains/{selector}`
/// returns `chainConfig` where each contract type is an array of versioned entries with `isActive`.
/// This source implements the address-bearing step 2. The API base URL can be overridden with the
/// non-secret `CCIP_API_BASE` environment variable (see `.env.example`).
contract CcipApiSource is IConfigSource {
    /// @dev Well-known cheatcode address (forge-std pattern) so this contract can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant HELPER = "script/config/ccip-config-source.sh";

    /// @inheritdoc IConfigSource
    /// @dev Uses `vm.tryFfi` so the helper's exit-code contract surfaces as a NAMED revert: the
    /// script writes a diagnostic to stderr (NOT_FOUND / API_UNREACHABLE / BAD_BODY / MISSING_TOOL)
    /// and that stderr becomes the revert reason here — never a raw "FFI failed" or a silent null.
    function fetchActiveCcipConfig(uint64 chainSelector) external returns (string memory flatJson) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = HELPER;
        cmd[2] = VM.toString(uint256(chainSelector));
        Vm.FfiResult memory r = VM.tryFfi(cmd);
        if (r.exitCode != 0) {
            revert(string(bytes.concat(bytes("[sync] config fetch failed: "), r.stderr)));
        }
        return string(r.stdout);
    }
}
