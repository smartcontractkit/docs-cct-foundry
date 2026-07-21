// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/contracts/interfaces/IGetCCIPAdmin.sol";
import {IOwner} from "@chainlink/contracts-ccip/contracts/interfaces/IOwner.sol";
import {PoolVersion} from "../utils/PoolVersion.s.sol";
import {DeploymentUtils} from "../utils/DeploymentUtils.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @notice Adopts an externally deployed token (and optionally its pool) into the address registry,
/// so contracts this repo did NOT deploy resolve exactly like the ones it did (the zero-export
/// `active.<role>` ladder). Validation happens on-chain BEFORE anything is written; a failed probe
/// refuses the adoption and writes nothing.
///
/// Validations:
///   - the token has code and a registration path is identified (`getCCIPAdmin()` preferred,
///     `owner()` fallback; exposing neither is a WARN, not a refusal, since the token may already
///     be registered in the TokenAdminRegistry)
///   - the pool (when given) has code, reports a supported contract version via `typeAndVersion()`
///     (see docs/pool-versions.md), and its `getToken()` matches the adopted token
///   - the TokenAdminRegistry state is read back and reported (administrator, pending
///     administrator, registered pool); a registered pool differing from the adopted one is a WARN
///
/// Usage (via the Makefile golden path):
///   make adopt-token CHAIN=<name> TOKEN=<addr> [TOKEN_POOL=<addr>]
contract AdoptToken is Script {
    string internal constant CONFIG_DIR = "config/chains/";

    /// @dev Everything validated about the adoption, resolved before any write.
    struct AdoptPlan {
        string selectorName; // the config/chains basename == the project-store basename
        uint256 chainId;
        address token;
        address pool;
        string tokenSymbol;
        string adminPath; // "getCCIPAdmin()", "owner()", or "" when self-registration is unavailable
        string poolTypeAndVersion; // full typeAndVersion() string; empty when no pool is adopted
    }

    function run(string memory name, address token, address pool) external {
        string memory path = string.concat(CONFIG_DIR, name, ".json");
        require(vm.exists(path), string.concat("no ", path, " - onboard the chain first: make add-chain"));
        string memory json = vm.readFile(path);
        uint256 chainId = vm.parseJsonUint(json, ".chainId");

        // Adoption validates live state, so the chain RPC is required (same resolution as the doctor).
        string memory rpcEnv = vm.parseJsonString(json, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        require(bytes(url).length > 0, string.concat("env ", rpcEnv, " unset - adoption validates on-chain state"));
        vm.createSelectFork(url);
        require(
            block.chainid == chainId,
            string.concat(
                "RPC chain id ",
                vm.toString(block.chainid),
                " != config chainId ",
                vm.toString(chainId),
                " - wrong RPC?"
            )
        );

        AdoptPlan memory plan = validateAdoption(json, chainId, token, pool);
        plan.selectorName = name;
        recordAdoption(plan);

        console.log("");
        console.log(string.concat(unicode"✅ Adopted into ", ProjectStore._display(name)));
        console.log("Next steps:");
        if (bytes(plan.adminPath).length > 0) {
            console.log(
                "  - register (if not yet): forge script script/setup/ClaimAdmin.s.sol, then AcceptAdminRole.s.sol"
            );
        }
        if (pool != address(0)) {
            console.log("  - point the registry at the pool: forge script script/setup/SetPool.s.sol");
            console.log("  - wire lanes: make add-lane LOCAL=... REMOTE=... CAPACITY=... RATE=...");
        }
        console.log("  - verify: make doctor CHAIN=<name>");
    }

    /// @notice On-chain validation of the adoption inputs. Reverts on anything that would record a
    ///         wrong or unusable entry; returns the fully resolved plan otherwise.
    function validateAdoption(string memory json, uint256 chainId, address token, address pool)
        public
        view
        returns (AdoptPlan memory plan)
    {
        require(token != address(0), "TOKEN is required");
        require(token.code.length > 0, string.concat("no contract code at token ", vm.toString(token)));

        plan.chainId = chainId;
        plan.token = token;
        plan.pool = pool;
        plan.tokenSymbol = DeploymentUtils._getSymbol(vm, token);

        console.log("");
        console.log("========================================");
        console.log(unicode"📥 Adopt externally deployed contracts");
        console.log("========================================");
        console.log(string.concat("Token:  ", vm.toString(token), " (", plan.tokenSymbol, ")"));

        // Registration path probe (the RegistryModuleOwnerCustom self-register check).
        try IGetCCIPAdmin(token).getCCIPAdmin() returns (address admin) {
            plan.adminPath = "getCCIPAdmin()";
            console.log(string.concat("  Registration path: getCCIPAdmin() -> ", vm.toString(admin)));
        } catch {
            try IOwner(token).owner() returns (address owner) {
                plan.adminPath = "owner()";
                console.log(string.concat("  Registration path: owner() -> ", vm.toString(owner)));
            } catch {
                console.log(unicode"  ⚠️  Token exposes neither getCCIPAdmin() nor owner():");
                console.log("      self-registration through the RegistryModuleOwnerCustom is unavailable.");
                console.log("      Adoption proceeds; registration must already exist or happen elsewhere.");
            }
        }

        if (pool != address(0)) {
            require(pool.code.length > 0, string.concat("no contract code at pool ", vm.toString(pool)));
            // The resolver gates adoption on the version catalog: it refuses non-pools, dev builds,
            // foreign pool types, and uncataloged versions by name (POOL_VERSION_OVERRIDE is honored
            // with its cross-check; the registry always records the TRUE on-chain string below, and
            // an override used here shows only in the console output).
            (, string memory full) = PoolVersion._resolve(pool);
            plan.poolTypeAndVersion = full;
            address poolToken = address(TokenPool(pool).getToken());
            require(
                poolToken == token,
                string.concat(
                    "pool/token mismatch: pool ",
                    vm.toString(pool),
                    " manages ",
                    vm.toString(poolToken),
                    ", not ",
                    vm.toString(token)
                )
            );
            console.log(string.concat("Pool:   ", vm.toString(pool), " (", plan.poolTypeAndVersion, ")"));
        }

        _reportRegistryState(json, token, pool);
        return plan;
    }

    /// @notice Records the validated plan into the address registry: `deployments` entries keyed by
    ///         symbol (and the pool's on-chain type and version) plus the `active.<role>` pointers,
    ///         through the same single-writer path the deploy scripts use.
    function recordAdoption(AdoptPlan memory plan) public {
        RegistryWriter._recordDeterministic(
            plan.selectorName, "token", string.concat(plan.tokenSymbol, "_Token"), plan.token
        );
        if (plan.pool != address(0)) {
            RegistryWriter._recordDeterministic(
                plan.selectorName,
                "tokenPool",
                string.concat(plan.tokenSymbol, "_", _spacesToUnderscores(plan.poolTypeAndVersion)),
                plan.pool
            );
        }
    }

    /// @notice **Non-EVM (base58) adopt path** - declare a project's Solana-side (or other non-EVM)
    /// token and pool as base58 strings into `project/<selectorName>.json`, so an EVM pool's
    /// `applyChainUpdates` can take the remote from the reviewed store instead of an ephemeral
    /// `DEST_TOKEN_POOL` env var. This repo forks EVM only, so there is NO on-chain probe here: the
    /// values are family-validated (base58 → exactly 32 bytes, via `RegistryWriter`) and recorded. The
    /// `run(string,address,address)` EVM signature cannot carry base58; this is its string-typed peer.
    ///   make adopt-token CHAIN=<solana-chain> TOKEN_B58=<base58> [POOL_B58=<base58>]
    ///
    /// The base58 value is checked ONLY to be a valid 32-byte key - it is NOT verified to be the right
    /// account. `POOL_B58` must be the account the remote chain's CCIP wiring expects as the remote
    /// pool address (for Solana, the pool's config account - not the pool program id or the token mint);
    /// a wrong-but-valid 32-byte key passes here but fails when a message is executed.
    ///
    /// Optional off-chain sanity check (advisory - this repo forks EVM only). Once the Solana side is
    /// deployed, stock CLIs confirm the values before wiring the lane:
    ///   solana account <POOL_B58> --url <cluster> --output json   # want: exists, executable:false,
    ///                                                             # owner == the CCIP pool program id
    ///   spl-token display <TOKEN_B58> --url <cluster>             # want: an SPL/Token-2022 mint
    /// A wrong key fails distinctly: the pool signer PDA -> AccountNotFound; the pool program id ->
    /// executable:true; the mint passed as the pool -> owner is a token program. Before the Solana side
    /// is deployed the account does not exist yet (AccountNotFound is expected), so this stays advisory.
    function runNonEvm(string memory name, string memory tokenBase58, string memory poolBase58) external {
        string memory path = string.concat(CONFIG_DIR, name, ".json");
        require(vm.exists(path), string.concat("no ", path, " - onboard the chain first: make add-chain"));
        string memory json = vm.readFile(path);
        require(
            keccak256(bytes(vm.parseJsonString(json, ".chainFamily"))) != keccak256(bytes("evm")),
            string.concat(name, " is an EVM chain - use the address-typed run(string,address,address) path")
        );
        require(bytes(tokenBase58).length != 0, "TOKEN_B58 is required");

        // RegistryWriter family-validates against config .chainFamily (base58 -> 32 bytes) and seeds
        // the project skeleton if absent.
        RegistryWriter._recordDeterministicString(name, "token", string.concat(name, "_token"), tokenBase58);
        if (bytes(poolBase58).length != 0) {
            RegistryWriter._recordDeterministicString(name, "tokenPool", string.concat(name, "_tokenPool"), poolBase58);
        }
        console.log(string.concat(unicode"✅ Declared non-EVM artifacts into ", ProjectStore._display(name)));
        console.log("  These base58 remotes now feed applyChainUpdates from the store (no env var needed).");
    }

    /// @dev Reads back and reports the TokenAdminRegistry state for the token; never reverts (a
    ///      not-yet-registered token is a valid adoption target).
    function _reportRegistryState(string memory json, address token, address pool) private view {
        if (!vm.keyExistsJson(json, ".ccip.tokenAdminRegistry")) return;
        address tar = vm.parseJsonAddress(json, ".ccip.tokenAdminRegistry");
        if (tar == address(0) || tar.code.length == 0) return;

        TokenAdminRegistry.TokenConfig memory cfg = TokenAdminRegistry(tar).getTokenConfig(token);
        if (cfg.administrator == address(0) && cfg.pendingAdministrator == address(0)) {
            console.log("TokenAdminRegistry: token not registered yet.");
            return;
        }
        console.log(string.concat("TokenAdminRegistry administrator:   ", vm.toString(cfg.administrator)));
        if (cfg.pendingAdministrator != address(0)) {
            console.log(string.concat("TokenAdminRegistry pending admin:   ", vm.toString(cfg.pendingAdministrator)));
        }
        address registeredPool = TokenAdminRegistry(tar).getPool(token);
        if (registeredPool != address(0)) {
            console.log(string.concat("TokenAdminRegistry registered pool: ", vm.toString(registeredPool)));
            if (pool != address(0) && registeredPool != pool) {
                console.log(unicode"  ⚠️  The adopted pool differs from the registered one; setPool moves it.");
            }
        }
    }

    function _spacesToUnderscores(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == 0x20) b[i] = 0x5f;
        }
        return string(b);
    }
}
