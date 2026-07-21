// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ChainConfig
/// @notice Chain metadata is DATA, not code: every CCIP address, chain selector, and chain label the
/// scripts need is read from a git-tracked `config/chains/<name>.json` file via `vm.parseJson*`
/// cheatcodes, so supporting a new chain is a config edit reviewed in a pull request - no Solidity
/// changes and no redeploy of anything.
/// @dev Schema per file (see `config/chains/ethereum-testnet-sepolia.json`):
///   - identity: `name`, `displayName`, `chainNameIdentifier` (the `{CHAIN}_*` env-var prefix,
///     e.g. `ETHEREUM_SEPOLIA`), `chainFamily` (`evm`/`svm`), `environment`, `chainId`,
///     `chainSelector`, `rpcEnv` (the env var holding the chain's RPC URL).
///   - `ccip{}`: the CCIP directory addresses (`router`, `rmnProxy`, `tokenAdminRegistry`,
///     `registryModuleOwnerCustom`, `link`, plus `feeQuoter`/`tokenPoolFactory`/`feeTokens`
///     kept for reference).
///   - repo extras: `explorerUrl`, `nativeCurrencySymbol`, and an optional hand-authored
///     `verifier{type,url}` block naming the explorer-verification backend (read by the verify
///     tooling and validated by the doctor, not parsed into `Chain`).
/// Project state (`lanes{}`, `roles{}`, deployed `addresses{}`) lives in `project/<selectorName>.json`,
/// NOT here - this file is PURE API/chain facts (see `docs/config-schema.md`).
/// `chainId` and `chainSelector` are quoted decimal STRINGS (uint64 selectors exceed JSON's safe
/// integer range) and are read with `vm.parseJsonUint`, which parses quoted decimals. Reads use
/// targeted key paths (`vm.parseJsonAddress(json, ".ccip.router")`) rather than whole-struct
/// decoding, which is field-order-sensitive and brittle.
library ChainConfig {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice One chain record, flattened from `config/chains/<name>.json`.
    struct Chain {
        uint64 chainSelector;
        address router;
        address rmnProxy;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address link;
        string chainName;
        string chainNameIdentifier;
        string explorerUrl;
        string nativeCurrencySymbol;
        string chainFamily;
    }

    function _path(string memory name) private view returns (string memory) {
        return string.concat(VM.projectRoot(), "/config/chains/", name, ".json");
    }

    /// @notice Reads a chain's full config record by config file name (e.g. "ethereum-testnet-sepolia").
    function _load(string memory name) internal view returns (Chain memory) {
        return _parse(VM.readFile(_path(name)));
    }

    /// @notice `load` + the declared chain ID, tolerating a file that no longer exists OR is only
    /// half-written (returns `ok = false`). Directory-scan consumers (see `names()`) race parallel
    /// tests that create/delete scratch configs, so BOTH the read AND the parse are guarded: a
    /// deleted file fails `readFile`; a mid-write file (`vm.writeJson` truncates then writes, so a
    /// concurrent reader can momentarily see partial, invalid JSON) fails the parse probe below.
    /// Either way the caller gets a clean `ok = false`, never an aborted `HelperConfig` construction.
    /// @dev The parse must be guarded, not just the read: `_parse` is an internal call, so its
    /// cheatcode reverts on invalid JSON would propagate PAST a `try` that only wraps `readFile`.
    /// `parseJsonUint(".chainId")` is the canary - it reverts on a partial document, and once it
    /// succeeds the file is complete valid JSON, so `_parse` reads every key without reverting.
    function _tryLoad(string memory name) internal view returns (bool ok, Chain memory c, uint256 declaredChainId) {
        if (!VM.exists(_path(name))) return (false, c, 0);
        string memory json;
        try VM.readFile(_path(name)) returns (string memory data) {
            json = data;
        } catch {
            return (false, c, 0);
        }
        try VM.parseJsonUint(json, ".chainId") returns (uint256 id) {
            declaredChainId = id;
        } catch {
            return (false, c, 0);
        }
        return (true, _parse(json), declaredChainId);
    }

    /// @dev Parses one already-read chain JSON document into a `Chain` record.
    function _parse(string memory json) private pure returns (Chain memory c) {
        c.chainSelector = uint64(VM.parseJsonUint(json, ".chainSelector"));
        c.router = VM.parseJsonAddress(json, ".ccip.router");
        c.rmnProxy = VM.parseJsonAddress(json, ".ccip.rmnProxy");
        c.tokenAdminRegistry = VM.parseJsonAddress(json, ".ccip.tokenAdminRegistry");
        c.registryModuleOwnerCustom = VM.parseJsonAddress(json, ".ccip.registryModuleOwnerCustom");
        c.link = VM.parseJsonAddress(json, ".ccip.link");
        c.chainName = VM.parseJsonString(json, ".displayName");
        c.chainNameIdentifier = VM.parseJsonString(json, ".chainNameIdentifier");
        c.explorerUrl = VM.parseJsonString(json, ".explorerUrl");
        c.nativeCurrencySymbol = VM.parseJsonString(json, ".nativeCurrencySymbol");
        c.chainFamily = VM.parseJsonString(json, ".chainFamily");
    }

    /// @notice The chain's declared EVM chain ID (`0` for non-EVM chains such as Solana).
    function _chainId(string memory name) internal view returns (uint256) {
        return VM.parseJsonUint(VM.readFile(_path(name)), ".chainId");
    }

    /// @notice The declared writer of this chain's `ccip{}` subtree, read from an already-loaded
    /// config document: `"api"` (the CCIP REST API sync owns the addresses) or `"manual"` (a reviewed
    /// hand edit owns them, for an address plane the API does not serve). The `configSource` key is
    /// optional; an absent key reads as `"api"`.
    function _configSource(string memory json) internal view returns (string memory) {
        if (!VM.keyExistsJson(json, ".configSource")) return "api";
        return VM.parseJsonString(json, ".configSource");
    }

    /// @notice True when this chain's `ccip{}` addresses are hand-maintained (`configSource: "manual"`),
    /// meaning the API sync must not write them and the doctor's API drift check does not apply.
    function _isManual(string memory json) internal view returns (bool) {
        return keccak256(bytes(_configSource(json))) == keccak256(bytes("manual"));
    }

    /// @notice True when `configSource` is one of the two known planes (`"api"` or `"manual"`), which
    /// includes an absent key (it reads as `"api"`). A present-but-unrecognized value is NOT known: the
    /// sync must refuse it rather than fall back to `"api"` and overwrite a plane the operator marked.
    function _isKnownConfigSource(string memory json) internal view returns (bool) {
        string memory source = _configSource(json);
        bytes32 h;
        assembly {
            h := keccak256(add(source, 0x20), mload(source))
        }
        return h == keccak256(bytes("api")) || h == keccak256(bytes("manual"));
    }

    /// @notice Enumerates every configured chain by scanning `config/chains/*.json` - the config
    /// name of each entry (file basename without `.json`, e.g. "ethereum-testnet-sepolia") feeds `load`.
    /// Directory contents ARE the chain list: dropping a new JSON file in makes the chain
    /// discoverable with no Solidity change.
    function _names() internal view returns (string[] memory) {
        Vm.DirEntry[] memory entries = VM.readDir(string.concat(VM.projectRoot(), "/config/chains"));
        string[] memory found = new string[](entries.length);
        uint256 count = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir) continue;
            string memory base = _jsonBasename(entries[i].path);
            if (bytes(base).length == 0) continue; // not a .json file
            found[count++] = base;
        }
        string[] memory out = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = found[i];
        }
        return out;
    }

    /// @dev Extracts the file basename without the `.json` extension; empty string when `path`
    /// is not a `.json` file.
    function _jsonBasename(string memory path) private pure returns (string memory) {
        bytes memory p = bytes(path);
        bytes memory ext = bytes(".json");
        if (p.length <= ext.length) return "";
        for (uint256 i = 0; i < ext.length; i++) {
            if (p[p.length - ext.length + i] != ext[i]) return "";
        }
        uint256 start = 0;
        for (uint256 i = p.length; i > 0; i--) {
            if (p[i - 1] == "/") {
                start = i;
                break;
            }
        }
        bytes memory out = new bytes(p.length - ext.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = p[start + i];
        }
        return string(out);
    }
}
