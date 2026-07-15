// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {RolesProbes} from "../../src/roles/RolesProbes.sol";

/// @title VerifyRoles
/// @notice **The privileged-role audit reader (read-only)** — prints the CURRENT holder of every
/// authority slot for a token / pool / lockbox / hooks set, resolved from `config/chains/<name>.json`
/// (+ `TOKEN`/`TOKEN_POOL` env overrides). Nothing broadcasts and no file is written; this is the
/// human-readable companion to `make roles-check` (which reconciles the declared `roles{}` against
/// the chain and exits 0/1/2). Use it during a handoff to eyeball the before/after holders, or for a
/// standalone audit of who holds what right now.
///
/// Every read goes through `RolesProbes`'s tolerant staticcalls, so a slot a given template/version
/// does not expose prints as "(absent)" rather than reverting the whole report — one reader covers
/// `CrossChainToken` / `BurnMintERC20` / `FactoryBurnMintERC20` / BYO tokens and v1.x / v2.0 pools.
///
///   forge script script/governance/VerifyRoles.s.sol --sig "run(string)" ethereum-testnet-sepolia --rpc-url <url>
///   TOKEN=0x.. TOKEN_POOL=0x.. forge script script/governance/VerifyRoles.s.sol --sig "run(string)" <name> --rpc-url <url>
contract VerifyRoles is Script {
    function run(string memory chainName) external view {
        (address token, address pool) = _resolve(chainName);
        console.log("=== VerifyRoles:", chainName, "===");
        console.log("token:", token);
        console.log("pool: ", pool);

        _reportToken(token);
        _reportTar(chainName, token);
        _reportPool(pool);
        _reportLockbox(pool);
        _reportHooks(pool);
    }

    function _resolve(string memory chainName) private view returns (address token, address pool) {
        ChainConfig.Chain memory c = ChainConfig.load(chainName);
        token = vm.envOr("TOKEN", RegistryWriter.read(c.chainSelector == 0 ? 0 : block.chainid, "token"));
        pool = vm.envOr("TOKEN_POOL", RegistryWriter.read(block.chainid, "tokenPool"));
        require(token != address(0), "no token: set TOKEN=<addr> or deploy first (addresses/<chainId>.json)");
        require(pool != address(0), "no pool: set TOKEN_POOL=<addr> or deploy first (addresses/<chainId>.json)");
    }

    // ---------------------------------------------------------------- token (template-dispatched)

    function _reportToken(address token) private view {
        RolesProbes.TokenTemplate t = RolesProbes.detectTemplate(token);
        console.log("--- token authority (template:", RolesProbes.templateName(t), ") ---");
        _logAddr("ccipAdmin           ", token, "getCCIPAdmin()");

        if (t == RolesProbes.TokenTemplate.CrossChainToken) {
            _logAddr("defaultAdmin        ", token, "defaultAdmin()");
            _logAddr("pendingDefaultAdmin ", token, "pendingDefaultAdmin()");
            _logRole("BURN_MINT_ADMIN_ROLE", token, RolesProbes.BURN_MINT_ADMIN_ROLE);
        } else if (t == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            _logAddr("owner               ", token, "owner()");
        } else if (t == RolesProbes.TokenTemplate.BurnMintERC20) {
            console.log(
                "  DEFAULT_ADMIN_ROLE  : multi-holder (enumerate via getRoleMember or snapshot SCAN_FROM_BLOCK)"
            );
        } else {
            // BYO: whichever universal admin point answers
            _logAddr("owner               ", token, "owner()");
            (bool hasAcl,) = RolesProbes.tryBytes32(token, "DEFAULT_ADMIN_ROLE()");
            console.log(
                "  DEFAULT_ADMIN_ROLE  :", hasAcl ? "present (point-check declared holders with hasRole)" : "(absent)"
            );
        }
        _reportMintBurn(token, t);
    }

    function _reportMintBurn(address token, RolesProbes.TokenTemplate t) private view {
        bytes32 minter = RolesProbes.roleIdOrDefault(token, "MINTER_ROLE()", RolesProbes.MINTER_ROLE);
        bytes32 burner = RolesProbes.roleIdOrDefault(token, "BURNER_ROLE()", RolesProbes.BURNER_ROLE);
        (bool mEnum, address[] memory minters) = RolesProbes.tryEnumerateHolders(token, "getMinters()", minter);
        (bool bEnum, address[] memory burners) = RolesProbes.tryEnumerateHolders(token, "getBurners()", burner);
        if (mEnum) {
            _logSet("MINTER_ROLE (complete)", minters);
        } else {
            console.log(
                t == RolesProbes.TokenTemplate.BYO
                    ? "  MINTER_ROLE         : not enumerable (byo - point-check known holders with hasRole)"
                    : "  MINTER_ROLE         : not enumerable (point-check known holders; snapshot SCAN_FROM_BLOCK to list)"
            );
        }
        if (bEnum) {
            _logSet("BURNER_ROLE (complete)", burners);
        } else {
            console.log(
                "  BURNER_ROLE         : not enumerable (point-check known holders; snapshot SCAN_FROM_BLOCK to list)"
            );
        }
    }

    // ---------------------------------------------------------------- TAR

    function _reportTar(string memory chainName, address token) private view {
        address tar = vm.envOr("TAR", ChainConfig.load(chainName).tokenAdminRegistry);
        console.log("--- TokenAdminRegistry (registry:", tar, ") ---");
        (bool s, bytes memory ret) = tar.staticcall(abi.encodeWithSignature("getTokenConfig(address)", token));
        if (!s || ret.length < 96) {
            console.log("  administrator       : (registry does not answer getTokenConfig)");
            return;
        }
        (address admin, address pending,) = abi.decode(ret, (address, address, address));
        console.log("  administrator       :", admin);
        console.log("  pendingAdministrator:", pending);
        console.log("  NOTE: the TAR CONTRACT owner is the network operator's - out of project scope");
    }

    // ---------------------------------------------------------------- pool

    function _reportPool(address pool) private view {
        (bool isV2, address router, address rateLimitAdmin, address feeAdmin) = RolesProbes.readPoolAdmins(pool);
        console.log("--- pool authority (generation:", isV2 ? "v2.0" : "v1.x", ") ---");
        _logAddr("owner               ", pool, "owner()");
        console.log("  router              :", router);
        console.log("  rateLimitAdmin      :", rateLimitAdmin);
        if (isV2) {
            console.log("  feeAdmin            :", feeAdmin);
            _logAddr("hooks               ", pool, "getAdvancedPoolHooks()");
        }
        _logAddr("rebalancer          ", pool, "getRebalancer()");
    }

    // ---------------------------------------------------------------- lockbox / hooks

    function _reportLockbox(address pool) private view {
        (bool has, address lockbox) = RolesProbes.tryAddress(pool, "getLockBox()");
        if (!has || lockbox == address(0)) return;
        console.log("--- lockbox authority (", lockbox, ") ---");
        _logAddr("owner               ", lockbox, "owner()");
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(lockbox, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        _logSet("authorizedCallers   ", callers);
    }

    function _reportHooks(address pool) private view {
        (bool has, address hooks) = RolesProbes.tryAddress(pool, "getAdvancedPoolHooks()");
        if (!has || hooks == address(0)) return;
        console.log("--- hooks authority (", hooks, ") ---");
        _logAddr("owner               ", hooks, "owner()");
        _logAddr("policyEngine        ", hooks, "getPolicyEngine()");
        (, bool allowlistEnabled) = RolesProbes.tryBool(hooks, "getAllowListEnabled()");
        console.log("  allowlistEnabled    :", allowlistEnabled);
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(hooks, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        _logSet("authorizedCallers   ", callers);
    }

    // ---------------------------------------------------------------- helpers

    function _logAddr(string memory label, address target, string memory sig) private view {
        (bool ok, address val) = RolesProbes.tryAddress(target, sig);
        if (ok) console.log(string.concat("  ", label, ":"), val);
        else console.log(string.concat("  ", label, ": (absent)"));
    }

    function _logRole(string memory label, address token, bytes32 role) private view {
        (bool enumerable, address[] memory holders) = RolesProbes.tryEnumerateHolders(token, "", role);
        if (enumerable) {
            _logSet(label, holders);
        } else {
            console.log(string.concat("  ", label, ": not enumerable (point-check known holders with hasRole)"));
        }
    }

    function _logSet(string memory label, address[] memory set) private pure {
        console.log(string.concat("  ", label, " (", vm.toString(set.length), "):"));
        for (uint256 i = 0; i < set.length; i++) {
            console.log("    ", set[i]);
        }
    }
}
