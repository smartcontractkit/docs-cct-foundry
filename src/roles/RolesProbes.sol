// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title RolesProbes
/// @notice Capability probes for the AUTHORITY surface — every read is a tolerant `staticcall`, so the
/// snapshot/auditor can dispatch on what a contract ACTUALLY exposes (the same philosophy as
/// `PoolVersions`: probe the surface, never trust a name). Used by both `RolesSnapshot` (backfill
/// declared state FROM chain) and `RolesAuditor` (reconcile declared state AGAINST chain).
/// @dev Role ids are the standard OZ/CCIP constants (keccak256 of the role name); a token's own
/// `MINTER_ROLE()`/`BURNER_ROLE()`/`BURN_MINT_ADMIN_ROLE()` getters take precedence when exposed
/// (`roleIdOrDefault`), so a token that renames its role ids still reconciles.
library RolesProbes {
    /// @notice The four token templates the roles engine dispatches on (`roles.token.type`).
    /// The admin MODEL differs per template, so nothing is assumed from a single variant:
    ///   - `CrossChainToken` (`"crosschain"`): OZ `AccessControlDefaultAdminRules` — single-holder
    ///     `DEFAULT_ADMIN_ROLE` read via `defaultAdmin()`, moved ONLY by the two-step
    ///     `beginDefaultAdminTransfer`/`acceptDefaultAdminTransfer`, plus the separate
    ///     `BURN_MINT_ADMIN_ROLE` that admins `MINTER_ROLE`/`BURNER_ROLE`.
    ///   - `BurnMintERC20` (`"burnmint"`): plain OZ `AccessControl` — multi-holder
    ///     `DEFAULT_ADMIN_ROLE` (grant/revoke), which directly admins mint/burn.
    ///   - `FactoryBurnMintERC20` (`"factory"`): `Ownable` — `owner()`-gated, with enumerable
    ///     `getMinters()`/`getBurners()` sets.
    ///   - `BYO` (`"byo"`): an unknown template — only the universal admin-registration points are
    ///     probed (`owner()`, `getCCIPAdmin()`, OZ `DEFAULT_ADMIN_ROLE` point-checks); every
    ///     token-internal role list stays declaration-backed and `complete: false`.
    enum TokenTemplate {
        BYO,
        CrossChainToken,
        BurnMintERC20,
        FactoryBurnMintERC20
    }

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    /// @dev The `CrossChainToken` role that is the role-admin of MINTER/BURNER — the slot a naive
    /// sweep forgets: it is granted at deploy and NOT moved when `DEFAULT_ADMIN_ROLE` transfers.
    bytes32 internal constant BURN_MINT_ADMIN_ROLE = keccak256("BURN_MINT_ADMIN_ROLE");
    // OZ TimelockController role ids (v4/v5 identical).
    bytes32 internal constant TIMELOCK_PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant TIMELOCK_CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant TIMELOCK_EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ---------------------------------------------------------------- generic tolerant getters

    function tryAddress(address target, string memory sig) internal view returns (bool ok, address val) {
        (bool s, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (s && ret.length >= 32) return (true, abi.decode(ret, (address)));
        return (false, address(0));
    }

    function tryUint(address target, string memory sig) internal view returns (bool ok, uint256 val) {
        (bool s, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (s && ret.length >= 32) return (true, abi.decode(ret, (uint256)));
        return (false, 0);
    }

    function tryBool(address target, string memory sig) internal view returns (bool ok, bool val) {
        (bool s, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (s && ret.length >= 32) return (true, abi.decode(ret, (bool)));
        return (false, false);
    }

    function tryBytes32(address target, string memory sig) internal view returns (bool ok, bytes32 val) {
        (bool s, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (s && ret.length >= 32) return (true, abi.decode(ret, (bytes32)));
        return (false, bytes32(0));
    }

    function tryAddressArray(address target, bytes memory callData)
        internal
        view
        returns (bool ok, address[] memory val)
    {
        (bool s, bytes memory ret) = target.staticcall(callData);
        // a dynamic array return is at least offset + length words
        if (s && ret.length >= 64) return (true, abi.decode(ret, (address[])));
        return (false, new address[](0));
    }

    // ---------------------------------------------------------------- token template dispatch

    /// @notice Detect the token's template from its ACTUAL surface (never from its name):
    /// `defaultAdmin()` + `DEFAULT_ADMIN_ROLE()` answering means `AccessControlDefaultAdminRules`
    /// (the `CrossChainToken` model); `DEFAULT_ADMIN_ROLE()` alone means plain `AccessControl`
    /// (the `BurnMintERC20` model); `owner()` alone means `Ownable` (the `FactoryBurnMintERC20`
    /// model); none of them means BYO (declaration-backed point-checks only).
    function detectTemplate(address token) internal view returns (TokenTemplate) {
        (bool hasAcl,) = tryBytes32(token, "DEFAULT_ADMIN_ROLE()");
        if (hasAcl) {
            (bool hasRules,) = tryAddress(token, "defaultAdmin()");
            return hasRules ? TokenTemplate.CrossChainToken : TokenTemplate.BurnMintERC20;
        }
        (bool hasOwner,) = tryAddress(token, "owner()");
        if (hasOwner) return TokenTemplate.FactoryBurnMintERC20;
        return TokenTemplate.BYO;
    }

    /// @notice The declared `roles.token.type` name for a template (`docs/config-schema.md`).
    function templateName(TokenTemplate t) internal pure returns (string memory) {
        if (t == TokenTemplate.CrossChainToken) return "crosschain";
        if (t == TokenTemplate.BurnMintERC20) return "burnmint";
        if (t == TokenTemplate.FactoryBurnMintERC20) return "factory";
        return "byo";
    }

    /// @notice Parse a declared `roles.token.type`; reverts on an unknown name so a typo in the
    /// declaration is a config error, never a silent BYO downgrade.
    function templateFromName(string memory name) internal pure returns (TokenTemplate) {
        bytes32 h;
        assembly {
            h := keccak256(add(name, 0x20), mload(name))
        }
        if (h == keccak256(bytes("crosschain"))) return TokenTemplate.CrossChainToken;
        if (h == keccak256(bytes("burnmint"))) return TokenTemplate.BurnMintERC20;
        if (h == keccak256(bytes("factory"))) return TokenTemplate.FactoryBurnMintERC20;
        if (h == keccak256(bytes("byo"))) return TokenTemplate.BYO;
        revert(string.concat("unknown roles.token.type '", name, "' (crosschain|burnmint|factory|byo)"));
    }

    /// @notice The token's own role id when exposed (e.g. `MINTER_ROLE()`), else the standard constant.
    function roleIdOrDefault(address token, string memory sig, bytes32 fallbackRole) internal view returns (bytes32) {
        (bool ok, bytes32 id) = tryBytes32(token, sig);
        return ok ? id : fallbackRole;
    }

    /// @notice The grantable/revocable token roles the token-role primitives dispatch on
    /// (`ROLE=minter|burner|burnMintAdmin|defaultAdmin`). `defaultAdmin` is the grant-model
    /// (`burnmint`) template's multi-holder DEFAULT_ADMIN_ROLE — its step-C revoke of the retired
    /// holder needs a primitive like every other role. On `crosschain` the single-holder default
    /// admin moves ONLY through the two-step transfer (`TransferTokenAdmin`), and on `factory` the
    /// top-level admin is the owner — both refuse `ROLE=defaultAdmin` by name.
    enum TokenRole {
        Minter,
        Burner,
        BurnMintAdmin,
        DefaultAdmin
    }

    /// @notice Parse a `ROLE=` name; reverts on an unknown name so a typo is a config error, never a
    /// silent grant of the wrong role.
    function tokenRoleFromName(string memory name) internal pure returns (TokenRole) {
        bytes32 h;
        assembly {
            h := keccak256(add(name, 0x20), mload(name))
        }
        if (h == keccak256(bytes("minter"))) return TokenRole.Minter;
        if (h == keccak256(bytes("burner"))) return TokenRole.Burner;
        if (h == keccak256(bytes("burnMintAdmin"))) return TokenRole.BurnMintAdmin;
        if (h == keccak256(bytes("defaultAdmin"))) return TokenRole.DefaultAdmin;
        revert(string.concat("unknown ROLE '", name, "' (minter|burner|burnMintAdmin|defaultAdmin)"));
    }

    /// @notice The `ROLE=` name for a token role.
    function tokenRoleName(TokenRole role) internal pure returns (string memory) {
        if (role == TokenRole.Minter) return "minter";
        if (role == TokenRole.Burner) return "burner";
        if (role == TokenRole.BurnMintAdmin) return "burnMintAdmin";
        return "defaultAdmin";
    }

    /// @notice Validate a (template, role) pair BEFORE any state-changing call. `BURN_MINT_ADMIN_ROLE`
    /// exists only on `CrossChainToken`: on any other AccessControl template `roleIdOrDefault` falls
    /// back to the standard constant, whose admin defaults to `DEFAULT_ADMIN_ROLE` in plain OZ
    /// AccessControl — a naive `grantRole` would SUCCEED on-chain and move nothing. `defaultAdmin`
    /// exists only on `burnmint` (grant-model): `crosschain` forbids grant/revoke of its default
    /// admin (two-step transfer only) and `factory` has an owner instead. A BYO token's internal
    /// roles are never movable through the primitives (the honest-coverage boundary).
    function requireRoleOnTemplate(TokenTemplate t, TokenRole role) internal pure {
        if (t == TokenTemplate.BYO) {
            revert("byo token: token-internal role moves are not supported (unknown template, complete:false surface)");
        }
        if (role == TokenRole.BurnMintAdmin && t != TokenTemplate.CrossChainToken) {
            revert(
                string.concat(
                    "ROLE=burnMintAdmin exists only on crosschain (CrossChainToken); this token probes as ",
                    templateName(t)
                )
            );
        }
        if (role == TokenRole.DefaultAdmin && t != TokenTemplate.BurnMintERC20) {
            revert(
                string.concat(
                    "ROLE=defaultAdmin exists only on burnmint (grant-model AccessControl); this token probes as ",
                    templateName(t),
                    t == TokenTemplate.CrossChainToken
                        ? " - move its default admin with TransferTokenAdmin (two-step)"
                        : " - move its owner with TransferTokenAdmin"
                )
            );
        }
    }

    /// @notice The resolved role id for an AccessControl-model token role (crosschain/burnmint). The
    /// factory template manages mint/burn through its Ownable set, not a role id — callers dispatch
    /// on the template before reaching for this.
    function tokenRoleId(address token, TokenRole role) internal view returns (bytes32) {
        if (role == TokenRole.Minter) return roleIdOrDefault(token, "MINTER_ROLE()", MINTER_ROLE);
        if (role == TokenRole.Burner) return roleIdOrDefault(token, "BURNER_ROLE()", BURNER_ROLE);
        if (role == TokenRole.BurnMintAdmin) {
            return roleIdOrDefault(token, "BURN_MINT_ADMIN_ROLE()", BURN_MINT_ADMIN_ROLE);
        }
        return DEFAULT_ADMIN_ROLE;
    }

    /// @notice The pending owner of a Chainlink `Ownable2Step`/`ConfirmedOwner` contract, read from
    /// storage — those bases keep `s_pendingOwner` PRIVATE with no getter, but the slot pair is fixed
    /// per compiled contract: {pendingOwner, owner} on `Ownable2Step` (pool 1.5.1+/2.0.0, lockbox,
    /// hooks) and the mirror {owner, pendingOwner} on `ConfirmedOwner` (1.5.0). The read is
    /// self-checked: the contract must expose `typeAndVersion()` (the known-Chainlink gate) and one
    /// of the two slots must equal the live `owner()` getter — the OTHER slot is then the pending.
    /// Neither matching means an unknown layout: refuse `(false, 0)` rather than return a value that
    /// merely looks like an answer. Forge-side only (`vm.load` needs an active fork).
    function tryPendingOwner(address target) internal view returns (bool ok, address pending) {
        Vm vmCheat = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        (bool hasTv, bytes memory tv) = target.staticcall(abi.encodeWithSignature("typeAndVersion()"));
        if (!hasTv || tv.length < 64) return (false, address(0));
        (bool hasOwner, address owner_) = tryAddress(target, "owner()");
        if (!hasOwner) return (false, address(0));
        bytes32 raw0 = vmCheat.load(target, bytes32(uint256(0)));
        bytes32 raw1 = vmCheat.load(target, bytes32(uint256(1)));
        // Both slots must be pure address words (upper 96 bits zero) - a packed or non-address slot
        // that happens to carry the owner's bytes in its low 160 bits must refuse, not misread.
        if (uint256(raw0) >> 160 != 0 || uint256(raw1) >> 160 != 0) return (false, address(0));
        address slot0 = address(uint160(uint256(raw0)));
        address slot1 = address(uint160(uint256(raw1)));
        if (slot1 == owner_) return (true, slot0);
        if (slot0 == owner_) return (true, slot1);
        return (false, address(0));
    }

    /// @notice Tolerant `hasRole` — false when the target has no AccessControl surface.
    function hasRole(address target, bytes32 role, address account) internal view returns (bool) {
        (bool s, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, account));
        return s && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @notice Tolerant Ownable-variant membership check (`isMinter(address)` / `isBurner(address)`).
    function isInOwnableSet(address token, string memory sig, address account) internal view returns (bool) {
        (bool s, bytes memory ret) = token.staticcall(abi.encodeWithSignature(sig, account));
        return s && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @notice ENUMERATE the holders of a role when the token allows it (complete list):
    /// (a) the Ownable EnumerableSet getters `getMinters()`/`getBurners()` (skipped when
    ///     `ownableGetterSig` is empty — admin roles have no Ownable-set analog);
    /// (b) `AccessControlEnumerable` (`getRoleMemberCount`/`getRoleMember`).
    /// Returns `(false, [])` when neither is exposed (the caller falls back to candidate checks).
    function tryEnumerateHolders(address token, string memory ownableGetterSig, bytes32 role)
        internal
        view
        returns (bool complete, address[] memory holders)
    {
        if (bytes(ownableGetterSig).length != 0) {
            (bool okSet, address[] memory set) = tryAddressArray(token, abi.encodeWithSignature(ownableGetterSig));
            if (okSet) return (true, set);
        }
        (bool s, bytes memory ret) = token.staticcall(abi.encodeWithSignature("getRoleMemberCount(bytes32)", role));
        if (!s || ret.length < 32) return (false, new address[](0));
        uint256 n = abi.decode(ret, (uint256));
        holders = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            (bool sm, bytes memory rm) =
                token.staticcall(abi.encodeWithSignature("getRoleMember(bytes32,uint256)", role, i));
            if (!sm || rm.length < 32) return (false, new address[](0));
            holders[i] = abi.decode(rm, (address));
        }
        return (true, holders);
    }

    // ---------------------------------------------------------------- pool surface (dual-generation)

    /// @notice Dual-generation pool admin read: v2 = `getDynamicConfig()` (router, rateLimitAdmin,
    /// feeAdmin); v1.x = `getRouter()` + `getRateLimitAdmin()` (NO feeAdmin surface).
    function readPoolAdmins(address pool)
        internal
        view
        returns (bool isV2, address router, address rateLimitAdmin, address feeAdmin)
    {
        (bool s, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("getDynamicConfig()"));
        if (s && ret.length >= 96) {
            (router, rateLimitAdmin, feeAdmin) = abi.decode(ret, (address, address, address));
            return (true, router, rateLimitAdmin, feeAdmin);
        }
        (, router) = tryAddress(pool, "getRouter()");
        (, rateLimitAdmin) = tryAddress(pool, "getRateLimitAdmin()");
        return (false, router, rateLimitAdmin, address(0));
    }

    // ---------------------------------------------------------------- governance probes

    /// @notice True when `candidate` walks and talks like a Safe (getThreshold + getOwners both answer).
    function looksLikeSafe(address candidate) internal view returns (bool) {
        if (candidate.code.length == 0) return false;
        (bool okT,) = tryUint(candidate, "getThreshold()");
        if (!okT) return false;
        (bool okO,) = tryAddressArray(candidate, abi.encodeWithSignature("getOwners()"));
        return okO;
    }

    /// @notice True when `candidate` answers the OZ TimelockController surface (getMinDelay).
    function looksLikeTimelock(address candidate) internal view returns (bool) {
        if (candidate.code.length == 0) return false;
        (bool ok,) = tryUint(candidate, "getMinDelay()");
        return ok;
    }

    // ---------------------------------------------------------------- set helpers

    /// @notice Order-insensitive two-sided address-set equality (duplicates count).
    function sameSet(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        bool[] memory used = new bool[](b.length);
        for (uint256 i = 0; i < a.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < b.length; j++) {
                if (!used[j] && a[i] == b[j]) {
                    used[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    function contains(address[] memory set, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == a) return true;
        }
        return false;
    }
}
