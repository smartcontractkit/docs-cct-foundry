// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ChainConfig} from "../src/config/ChainConfig.sol";
import {RegistryWriter} from "../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../src/utils/ProjectStore.sol";

/// @notice Network configuration helper. Chain metadata (selectors, CCIP addresses, chain labels)
/// lives in git-tracked JSON files under `config/chains/` and is read through `ChainConfig` —
/// supporting a new chain is a config edit, not a Solidity change: the chain LIST itself is
/// discovered by scanning `config/chains/*.json` once at construction into a storage cache (the
/// per-chain constants and getters below are kept as fast paths; every lookup falls back to the
/// discovered-chain cache for chains added after they were written). Deployed contract addresses
/// resolve from environment variables first, then from the project store
/// `project/<selectorName>.json` `addresses.active.<role>` written by the deploy scripts (see
/// `RegistryWriter`).
contract HelperConfig is Script {
    struct NetworkConfig {
        uint64 chainSelector;
        address router;
        address rmnProxy;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address link;
        uint256 confirmations;
        string chainName;
        string chainNameIdentifier;
        string explorerUrl;
        string nativeCurrencySymbol;
        string chainFamily;
    }

    // Chain IDs
    uint256 public constant ETHEREUM_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ZERO_G_TESTNET_CHAIN_ID = 16602;
    uint256 public constant PLUME_TESTNET_CHAIN_ID = 98867;
    uint256 public constant INK_SEPOLIA_CHAIN_ID = 763373;
    uint256 public constant MANTLE_SEPOLIA_CHAIN_ID = 5003;

    // Deployed contract addresses — EVM chains, keyed by chainId (the FROZEN getter surface).
    mapping(uint256 => address) public deployedTokens;
    mapping(uint256 => address) public deployedTokenPools;
    mapping(uint256 => address) public deployedLockBoxes;
    mapping(uint256 => address) public deployedPoolHooks;

    // Non-EVM artifacts, keyed by `<selectorName>:<role>` — every non-EVM chain reports chainId "0",
    // so the chainId-keyed maps above cannot key them. Values are RAW strings (base58 for Solana) the
    // project store resolves, so an EVM pool's applyChainUpdates can take a Solana remote from the
    // store instead of an ephemeral env var. Resolved via `getDeployed*String(selectorName)`.
    mapping(string => string) private s_deployedString;

    // Discovered-chain cache: `config/chains/*.json` is scanned ONCE at construction and every
    // record is kept in storage — the scan fallbacks below never touch the filesystem again.
    string[] private s_configuredChains; // config names (file basenames == selectorNames), same order as s_chains
    NetworkConfig[] private s_chains;
    uint256[] private s_chainIds; // declared chainId per entry (0 for non-EVM chains)

    constructor() {
        // Discover every configured chain from `config/chains/*.json` — a chain added by
        // `make add-chain` is picked up automatically, no Solidity change — then initialize
        // deployed contracts (env vars / the project store) for each chain. Non-EVM chains resolve
        // too: their base58 artifacts feed applyChainUpdates.
        string[] memory chains = ChainConfig.names();
        for (uint256 i = 0; i < chains.length; i++) {
            (bool ok, ChainConfig.Chain memory c, uint256 chainId) = ChainConfig.tryLoad(chains[i]);
            if (!ok) continue; // deleted between the directory scan and the read (parallel tests)
            s_configuredChains.push(chains[i]);
            s_chains.push(_toNetworkConfig(c));
            s_chainIds.push(chainId);
            if (chainId != 0) {
                _initializeDeployedContracts(chainId, chains[i], c.chainNameIdentifier);
            } else {
                _initializeNonEvmArtifacts(chains[i], c.chainNameIdentifier);
            }
        }
        // Surface an env override that diverges from the store, for the ACTING chain only (its own
        // resolution just ran above). No-op unless the run is forked to a configured chain, so an
        // unforked dry-run stays quiet; `warnEnvOverride` is itself silent under `forge test`.
        (bool acting,) = _findByChainId(block.chainid);
        if (acting) warnEnvOverride(block.chainid);
    }

    /// @dev Helper to initialize deployed contract addresses (EVM chains, address-typed).
    ///
    /// Resolution order (highest priority first):
    ///   1. Inline short alias — `TOKEN` / `TOKEN_POOL`
    ///      Pass directly on the command line without exporting:
    ///      `TOKEN=0x... TOKEN_POOL=0x... forge script ...`
    ///   2. Chain-specific var — `{CHAIN}_TOKEN` / `{CHAIN}_TOKEN_POOL`
    ///      Set once per session: `export ETHEREUM_SEPOLIA_TOKEN=0x...`
    ///   3. Project store — `project/<selectorName>.json` `addresses.active.<role>`, written
    ///      automatically by the deploy scripts (and `adopt-token`). This is the default: after a
    ///      deploy, later scripts resolve the address with no environment variable at all.
    ///
    /// An env override wins as-is and is READ-ONLY (it never writes the store back). A broadcasting
    /// script surfaces the divergence with `warnEnvOverride` — one notice naming both values and the
    /// `make adopt-token` reconcile command.
    function _initializeDeployedContracts(uint256 chainId, string memory selectorName, string memory chainNameId)
        private
    {
        // Initialize TOKEN contract — inline TOKEN alias takes priority
        address token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) {
            token = vm.envOr(string.concat(chainNameId, "_TOKEN"), address(0));
        }
        if (token == address(0)) {
            token = RegistryWriter.read(selectorName, "token");
        }
        deployedTokens[chainId] = token;

        // Initialize TOKEN_POOL contract — inline TOKEN_POOL alias takes priority
        address tokenPool = vm.envOr("TOKEN_POOL", address(0));
        if (tokenPool == address(0)) {
            tokenPool = vm.envOr(string.concat(chainNameId, "_TOKEN_POOL"), address(0));
        }
        if (tokenPool == address(0)) {
            tokenPool = RegistryWriter.read(selectorName, "tokenPool");
        }
        deployedTokenPools[chainId] = tokenPool;

        // Initialize LOCK_BOX — inline LOCK_BOX alias > {CHAIN}_LOCK_BOX > store active.lockBox
        address lockBox = vm.envOr("LOCK_BOX", address(0));
        if (lockBox == address(0)) {
            lockBox = vm.envOr(string.concat(chainNameId, "_LOCK_BOX"), address(0));
        }
        if (lockBox == address(0)) {
            lockBox = RegistryWriter.read(selectorName, "lockBox");
        }
        deployedLockBoxes[chainId] = lockBox;

        // Initialize POOL_HOOKS — inline POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > store active.poolHooks
        address poolHooks = vm.envOr("POOL_HOOKS", address(0));
        if (poolHooks == address(0)) {
            poolHooks = vm.envOr(string.concat(chainNameId, "_POOL_HOOKS"), address(0));
        }
        if (poolHooks == address(0)) {
            poolHooks = RegistryWriter.read(selectorName, "poolHooks");
        }
        deployedPoolHooks[chainId] = poolHooks;
    }

    /// @dev Initialize a non-EVM chain's project artifacts (RAW base58 strings), keyed by
    /// `<selectorName>:<role>`. Non-EVM chains all report chainId "0", so the chainId-keyed maps
    /// cannot hold them; the selectorName-keyed string cache is the non-EVM resolution surface.
    /// Ladder: chain-scoped env (`{CHAIN}_TOKEN` / `{CHAIN}_TOKEN_POOL`) > store `active.<role>`.
    /// (The inline `TOKEN` alias is deliberately NOT applied here: it is a chain-agnostic override
    /// and would smear one address across every configured chain — a documented footgun.)
    function _initializeNonEvmArtifacts(string memory selectorName, string memory chainNameId) private {
        _initNonEvmRole(selectorName, chainNameId, "token", "_TOKEN");
        _initNonEvmRole(selectorName, chainNameId, "tokenPool", "_TOKEN_POOL");
    }

    function _initNonEvmRole(
        string memory selectorName,
        string memory chainNameId,
        string memory role,
        string memory envSuffix
    ) private {
        string memory val = vm.envOr(string.concat(chainNameId, envSuffix), string(""));
        if (bytes(val).length == 0) {
            val = RegistryWriter.readString(selectorName, role);
        }
        s_deployedString[string.concat(selectorName, ":", role)] = val;
    }

    /// @notice Surface an env override that diverges from the project store, for the ACTING chain.
    /// When a role (`token`/`tokenPool`/`lockBox`/`poolHooks`) resolves from an env rung whose value
    /// differs from `project/<selectorName>.json` `addresses.active.<role>`, print ONE notice naming
    /// both values and the `make adopt-token` reconcile command. The override wins and is READ-ONLY
    /// (the store is never written back), so this is the only thing that keeps a reviewed store from
    /// silently drifting under an incident override. Silent when no override is set, when env == store,
    /// and under `forge test`. Acting chain only (its own `chainId`), so the chain-agnostic inline
    /// `TOKEN` alias never smears a notice across every configured chain. Broadcasting scripts call
    /// this once, after resolving their inputs.
    function warnEnvOverride(uint256 chainId) public view {
        if (vm.isContext(VmSafe.ForgeContext.TestGroup)) return; // never under forge test
        if (chainId == 0) return; // broadcasting is EVM-only; non-EVM chains have no acting chainId
        string memory selectorName = getSelectorName(chainId);
        string memory chainNameId = getNetworkConfig(chainId).chainNameIdentifier;
        _warnRoleDivergence(selectorName, chainNameId, "token", "TOKEN");
        _warnRoleDivergence(selectorName, chainNameId, "tokenPool", "TOKEN_POOL");
        _warnRoleDivergence(selectorName, chainNameId, "lockBox", "LOCK_BOX");
        _warnRoleDivergence(selectorName, chainNameId, "poolHooks", "POOL_HOOKS");
    }

    function _warnRoleDivergence(
        string memory selectorName,
        string memory chainNameId,
        string memory role,
        string memory envStem
    ) private view {
        address envVal = vm.envOr(envStem, address(0));
        if (envVal == address(0)) envVal = vm.envOr(string.concat(chainNameId, "_", envStem), address(0));
        string memory notice =
            composeDivergenceNotice(selectorName, role, envStem, envVal, RegistryWriter.read(selectorName, role));
        if (bytes(notice).length != 0) console.log(notice);
    }

    /// @notice The divergence-notice text for one role, or "" when silent. Side-effect free so the four
    /// resolution states are byte-assertable in a test without env/store setup: `envVal == 0` (no
    /// override) → ""; `envVal == storeVal` (override matches store) → ""; otherwise (override differs,
    /// or the store is unset) → a two-line notice naming both values and the exact `make adopt-token`
    /// reconcile command.
    function composeDivergenceNotice(
        string memory selectorName,
        string memory role,
        string memory envStem,
        address envVal,
        address storeVal
    ) public view returns (string memory) {
        if (envVal == address(0) || envVal == storeVal) return "";
        return string.concat(
            "NOTICE: ",
            role,
            " resolved from env (",
            vm.toString(envVal),
            ") but ",
            ProjectStore.display(selectorName),
            " addresses.active.",
            role,
            " = ",
            storeVal == address(0) ? "(unset)" : vm.toString(storeVal),
            "\n        The override wins for this run and is NOT written back. If ",
            vm.toString(envVal),
            " is the new truth, reconcile the store: make adopt-token CHAIN=",
            selectorName,
            " ",
            envStem,
            "=",
            vm.toString(envVal)
        );
    }

    /// @dev Maps a NetworkConfig from a `config/chains/<name>.json` record.
    function _load(string memory configName) private view returns (NetworkConfig memory) {
        return _toNetworkConfig(ChainConfig.load(configName));
    }

    function _toNetworkConfig(ChainConfig.Chain memory c) private pure returns (NetworkConfig memory) {
        return NetworkConfig({
            chainSelector: c.chainSelector,
            router: c.router,
            rmnProxy: c.rmnProxy,
            tokenAdminRegistry: c.tokenAdminRegistry,
            registryModuleOwnerCustom: c.registryModuleOwnerCustom,
            link: c.link,
            confirmations: c.confirmations,
            chainName: c.chainName,
            chainNameIdentifier: c.chainNameIdentifier,
            explorerUrl: c.explorerUrl,
            nativeCurrencySymbol: c.nativeCurrencySymbol,
            chainFamily: c.chainFamily
        });
    }

    /// @notice Resolves an EVM `chainId` to its canonical **selectorName** (the `config/chains/`
    /// basename == the project-store basename). The chainId→selectorName resolver that keeps the
    /// frozen `getNetworkConfig(chainId)` surface while the store keys by selectorName. Reverts for a
    /// non-EVM chainId (`0` is shared by every non-EVM chain and cannot resolve to one name — resolve
    /// those by selectorName directly).
    function getSelectorName(uint256 chainId) public view returns (string memory) {
        require(chainId != 0, "getSelectorName: non-EVM chains share chainId 0 - resolve by selectorName");
        for (uint256 i = 0; i < s_chainIds.length; i++) {
            if (s_chainIds[i] == chainId) return s_configuredChains[i];
        }
        revert("Unsupported chain ID");
    }

    /// @notice Resolves a chainSelector to its selectorName (the config basename == project-store
    /// basename). Works for every family (non-EVM chains share chainId 0 but have unique selectors),
    /// so it is the join key for resolving a non-EVM remote's stored artifacts. "" when no config
    /// declares the selector.
    function getSelectorNameBySelector(uint64 chainSelector) public view returns (string memory) {
        for (uint256 i = 0; i < s_chains.length; i++) {
            if (s_chains[i].chainSelector == chainSelector) return s_configuredChains[i];
        }
        return "";
    }

    /// @notice Resolves a non-EVM chain's active `token` artifact as a RAW string (base58 for Solana)
    /// via the selectorName-keyed cache (chain-scoped env > store). Empty when unresolved. This is the
    /// non-EVM resolution surface the frozen chainId-keyed `getDeployedToken` cannot serve.
    function getDeployedTokenString(string memory selectorName) public view returns (string memory) {
        return s_deployedString[string.concat(selectorName, ":token")];
    }

    /// @notice Resolves a non-EVM chain's active `tokenPool` artifact as a RAW string (base58 for
    /// Solana) via the selectorName-keyed cache (chain-scoped env > store). Empty when unresolved.
    function getDeployedTokenPoolString(string memory selectorName) public view returns (string memory) {
        return s_deployedString[string.concat(selectorName, ":tokenPool")];
    }

    function getEthereumSepoliaConfig() public view returns (NetworkConfig memory) {
        return _load("ethereum-testnet-sepolia");
    }

    function getZeroGTestnetConfig() public view returns (NetworkConfig memory) {
        return _load("0g-testnet-galileo-1");
    }

    function getPlumeTestnetConfig() public view returns (NetworkConfig memory) {
        return _load("plume-testnet-sepolia");
    }

    function getInkSepoliaConfig() public view returns (NetworkConfig memory) {
        return _load("ink-testnet-sepolia");
    }

    function getMantleSepoliaConfig() public view returns (NetworkConfig memory) {
        return _load("ethereum-testnet-sepolia-mantle-1");
    }

    // ── Non-EVM destination chains ──────────────────────────────────────────────────────────────
    // Non-EVM chains are only supported as the **destination** chain when calling ApplyChainUpdates
    // — i.e. to register a non-EVM token pool on an EVM source chain. They cannot be used as
    // source chains in this repo.
    // That's why fields like router, rmnProxy, tokenAdminRegistry, etc. are not applicable
    // and are intentionally zero/empty in `config/chains/solana-devnet.json`.
    // Add more entries under `config/chains/` as new non-EVM lanes go live.

    /// @notice Returns the network configuration for Solana Devnet.
    /// @dev Only chainSelector, chainName, chainNameIdentifier, nativeCurrencySymbol, and chainFamily are used.
    function getSolanaDevnetConfig() public view returns (NetworkConfig memory) {
        return _load("solana-devnet");
    }

    /// @notice Resolves a chain name (e.g. "SOLANA_DEVNET", "AVALANCHE_FUJI") to its NetworkConfig.
    /// @dev Handles both EVM and non-EVM chains. Returns a zero config (chainFamily = "") for
    ///      unrecognized names so callers can fall back to DEST_CHAIN_FAMILY / DEST_CHAIN_SELECTOR.
    function getDestChainConfig(string memory chainName) public view returns (NetworkConfig memory) {
        bytes32 h = keccak256(abi.encodePacked(chainName));
        if (h == keccak256(abi.encodePacked("ETHEREUM_SEPOLIA"))) return getEthereumSepoliaConfig();
        if (h == keccak256(abi.encodePacked("ZERO_G_TESTNET"))) return getZeroGTestnetConfig();
        if (h == keccak256(abi.encodePacked("PLUME_TESTNET"))) return getPlumeTestnetConfig();
        if (h == keccak256(abi.encodePacked("INK_SEPOLIA"))) return getInkSepoliaConfig();
        if (h == keccak256(abi.encodePacked("MANTLE_SEPOLIA"))) return getMantleSepoliaConfig();
        if (h == keccak256(abi.encodePacked("SOLANA_DEVNET"))) return getSolanaDevnetConfig();
        // Fall back to the discovered-chain cache for chains added after this dispatch was written.
        (bool found, uint256 idx) = _findByIdentifier(chainName);
        if (found) return s_chains[idx];
        NetworkConfig memory unknown;
        return unknown;
    }

    function getNetworkConfig(uint256 chainId) public view returns (NetworkConfig memory) {
        // Fast path: the chains this dispatch was written for.
        if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) {
            return getEthereumSepoliaConfig();
        } else if (chainId == ZERO_G_TESTNET_CHAIN_ID) {
            return getZeroGTestnetConfig();
        } else if (chainId == PLUME_TESTNET_CHAIN_ID) {
            return getPlumeTestnetConfig();
        } else if (chainId == INK_SEPOLIA_CHAIN_ID) {
            return getInkSepoliaConfig();
        } else if (chainId == MANTLE_SEPOLIA_CHAIN_ID) {
            return getMantleSepoliaConfig();
        }
        // Fallback: the discovered-chain cache (scanned from config/chains/*.json at
        // construction) — a chain added by `make add-chain` resolves here with no Solidity change.
        (bool found, uint256 idx) = _findByChainId(chainId);
        if (found) return s_chains[idx];
        revert("Unsupported chain ID");
    }

    /// @notice Enumerates every configured chain (config names, i.e. `config/chains/<name>.json`
    /// basenames as discovered at construction) — the dynamic chain list backing the fallbacks above.
    function getConfiguredChains() public view returns (string[] memory) {
        return s_configuredChains;
    }

    /// @dev Cache index of the discovered chain whose declared `chainId` matches. Non-EVM
    ///      chains declare `chainId` 0 and never match (callers must pass a real EVM chain ID).
    function _findByChainId(uint256 chainId) private view returns (bool, uint256) {
        if (chainId == 0) return (false, 0);
        for (uint256 i = 0; i < s_chainIds.length; i++) {
            if (s_chainIds[i] == chainId) return (true, i);
        }
        return (false, 0);
    }

    /// @dev Cache index of the discovered chain whose `chainNameIdentifier` matches.
    function _findByIdentifier(string memory chainNameIdentifier) private view returns (bool, uint256) {
        bytes32 nameHash = keccak256(abi.encodePacked(chainNameIdentifier));
        for (uint256 i = 0; i < s_chains.length; i++) {
            if (keccak256(abi.encodePacked(s_chains[i].chainNameIdentifier)) == nameHash) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function getDeployedToken(uint256 chainId) public view returns (address) {
        return deployedTokens[chainId];
    }

    function getDeployedTokenPool(uint256 chainId) public view returns (address) {
        return deployedTokenPools[chainId];
    }

    /// @notice Resolves the deployed ERC20LockBox for this chain via the same 3-rung ladder as
    /// token/tokenPool: inline `LOCK_BOX` alias > `{CHAIN}_LOCK_BOX` env > registry `active.lockBox`.
    /// `address(0)` when unresolved (callers requiring it must revert with a clear message).
    function getDeployedLockBox(uint256 chainId) public view returns (address) {
        return deployedLockBoxes[chainId];
    }

    /// @notice Resolves the deployed AdvancedPoolHooks for this chain via the same 3-rung ladder as
    /// token/tokenPool: inline `POOL_HOOKS` alias > `{CHAIN}_POOL_HOOKS` env > registry `active.poolHooks`.
    /// `address(0)` when unresolved.
    function getDeployedPoolHooks(uint256 chainId) public view returns (address) {
        return deployedPoolHooks[chainId];
    }

    /// @dev Converts a chain name identifier (e.g. "AVALANCHE_FUJI") to its EVM chain ID.
    ///      EVM chains only — non-EVM chains (e.g. "SOLANA_DEVNET") have no EVM chain ID
    ///      and will revert with "Invalid chain name".
    function parseChainName(string memory chainName) public view returns (uint256) {
        bytes32 nameHash = keccak256(abi.encodePacked(chainName));

        if (nameHash == keccak256(abi.encodePacked(getEthereumSepoliaConfig().chainNameIdentifier))) {
            return ETHEREUM_SEPOLIA_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getZeroGTestnetConfig().chainNameIdentifier))) {
            return ZERO_G_TESTNET_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getPlumeTestnetConfig().chainNameIdentifier))) {
            return PLUME_TESTNET_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getInkSepoliaConfig().chainNameIdentifier))) {
            return INK_SEPOLIA_CHAIN_ID;
        }
        if (nameHash == keccak256(abi.encodePacked(getMantleSepoliaConfig().chainNameIdentifier))) {
            return MANTLE_SEPOLIA_CHAIN_ID;
        }

        // Fallback: the discovered-chain cache. Non-EVM matches (chainId 0) keep reverting —
        // they have no EVM chain ID.
        (bool found, uint256 idx) = _findByIdentifier(chainName);
        if (found && s_chainIds[idx] != 0) return s_chainIds[idx];
        revert("Invalid chain name");
    }

    function getChainName(uint256 chainId) public view returns (string memory) {
        return getNetworkConfig(chainId).chainName;
    }

    function getChainNameBySelector(uint64 chainSelector) public view returns (string memory) {
        if (chainSelector == getEthereumSepoliaConfig().chainSelector) return getEthereumSepoliaConfig().chainName;
        if (chainSelector == getZeroGTestnetConfig().chainSelector) return getZeroGTestnetConfig().chainName;
        if (chainSelector == getPlumeTestnetConfig().chainSelector) return getPlumeTestnetConfig().chainName;
        if (chainSelector == getInkSepoliaConfig().chainSelector) return getInkSepoliaConfig().chainName;
        if (chainSelector == getMantleSepoliaConfig().chainSelector) return getMantleSepoliaConfig().chainName;
        if (chainSelector == getSolanaDevnetConfig().chainSelector) return getSolanaDevnetConfig().chainName;
        // Fallback: the discovered-chain cache.
        for (uint256 i = 0; i < s_chains.length; i++) {
            if (s_chains[i].chainSelector == chainSelector) return s_chains[i].chainName;
        }
        return "Unknown";
    }

    function getNativeCurrencySymbol(uint256 chainId) public view returns (string memory) {
        return getNetworkConfig(chainId).nativeCurrencySymbol;
    }

    function getExplorerUrl(uint256 chainId, string memory pathType, address contractAddress)
        public
        view
        returns (string memory)
    {
        return string.concat(getNetworkConfig(chainId).explorerUrl, pathType, vm.toString(contractAddress));
    }
}
