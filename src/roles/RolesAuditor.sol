// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {RolesProbes} from "./RolesProbes.sol";

/// @title RolesAuditor
/// @notice Reconciles the DECLARED authority surface (`roles{}` in `config/chains/<name>.json`) against
/// the live chain (the active fork must be the chain itself). One aligned [PASS]/[FAIL]/[WARN]/[SKIP]
/// line per field — the same doctor style as `VerifyChain`, which mounts this as its ROLES rung;
/// `make roles-check` runs it standalone through the exit-code wrapper (`script/config/roles-check.sh`).
/// @dev Semantics (docs/config-schema.md, `roles{}`):
///   - every DECLARED holder is verified live by a point-read (`owner()`/`defaultAdmin()`/`hasRole`/
///     `getCCIPAdmin()`/TAR `getTokenConfig`/...) — plain `eth_call`s, reliable on any RPC, no
///     `getLogs` (the reconcile that matters is never at the mercy of RPC log limits);
///   - ENUMERABLE sets (lockbox/hooks authorizedCallers, hooks allowlist, safe owners, factory-token
///     minters/burners) get a full two-sided set compare;
///   - non-enumerable holder lists verify declared-entries-hold and surface the `"complete": false`
///     marker as a WARN (a partial list is never silently treated as full);
///   - the token block dispatches on the declared `type` (`crosschain`/`burnmint`/`factory`/`byo`);
///     a declared type that contradicts the probed surface FAILs (except `byo`, which never assumes);
///   - an ABSENT optional block (`governance{}` on an EOA chain, lockbox on a burnmint chain) is a
///     SKIP, never a FAIL — `governance{}` supports three shapes (safe only / timelock only / both);
///   - the TAR CONTRACT's own `owner()` is the network operator's authority, deliberately out of
///     scope — never read, never a FAIL;
///   - cross-consistency WARNs: timelock declared without the safe among proposers; a declared safe
///     that is NOT the pool's `rateLimitAdmin` (the emergency-throttle convention).
contract RolesAuditor {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Result {
        uint256 passes;
        uint256 warns;
        uint256 skips;
        uint256 fails;
        string failedFields; // comma-separated declared-field names that mismatched
        string skippedBlocks; // comma-separated absent optional blocks
    }

    Result private r;

    /// @notice Audit `name` using its on-disk config (the common path).
    function audit(string memory name) external returns (Result memory) {
        return this.auditJson(name, VM.readFile(string.concat("config/chains/", name, ".json")));
    }

    /// @notice Audit against an EXPLICIT config JSON (lets tests reconcile a mutated declared state
    /// without touching the real files). The active fork must be the chain itself.
    function auditJson(string memory name, string memory json) external returns (Result memory) {
        delete r;
        require(VM.keyExistsJson(json, ".roles"), string.concat("no roles{} declared for ", name));

        address token = _requiredAddress(json, ".roles.token.address", "token.address");
        address pool = _requiredAddress(json, ".roles.pool.address", "pool.address");

        if (token != address(0)) _auditToken(json, token);
        if (token != address(0)) {
            _auditTar(json, token);
        } else if (VM.keyExistsJson(json, ".roles.tokenAdminRegistry")) {
            _skip("tokenAdminRegistry", "token.address anchor missing - cannot resolve the TAR registration");
        }
        if (pool != address(0)) _auditPool(json, pool);
        _auditLockbox(json, pool);
        _auditHooks(json);
        _auditRebalancer(json, pool);
        _auditGovernance(json);

        console.log(
            string.concat(
                "roles: ",
                VM.toString(r.fails),
                " FAIL, ",
                VM.toString(r.warns),
                " WARN, ",
                VM.toString(r.skips),
                " SKIP (",
                name,
                ")"
            )
        );
        return r;
    }

    /// @dev The declaration is self-contained: `roles.token.address`/`roles.pool.address` anchor every
    /// other field (the gitignored addresses registry is NOT consulted at audit time). Missing anchor
    /// = FAIL naming the field, and the dependent rungs are skipped rather than crashed.
    function _requiredAddress(string memory json, string memory path, string memory field) private returns (address a) {
        if (!VM.keyExistsJson(json, path)) {
            _fail(field, "not declared - roles{} must anchor its own addresses (run make snapshot-chain)");
            return address(0);
        }
        return VM.parseJsonAddress(json, path);
    }

    // ---------------------------------------------------------------- reporting

    function _pass(string memory field, string memory detail) private {
        r.passes++;
        console.log(string.concat("[PASS] roles.", field, ": ", detail));
    }

    function _fail(string memory field, string memory detail) private {
        r.fails++;
        r.failedFields = bytes(r.failedFields).length == 0 ? field : string.concat(r.failedFields, ", ", field);
        console.log(string.concat("[FAIL] roles.", field, ": ", detail));
    }

    function _warn(string memory field, string memory detail) private {
        r.warns++;
        console.log(string.concat("[WARN] roles.", field, ": ", detail));
    }

    function _skip(string memory block_, string memory detail) private {
        r.skips++;
        r.skippedBlocks = bytes(r.skippedBlocks).length == 0 ? block_ : string.concat(r.skippedBlocks, ", ", block_);
        console.log(string.concat("[SKIP] roles.", block_, ": ", detail));
    }

    function _checkAddress(string memory field, address declared, address live) private {
        if (declared == live) {
            _pass(field, VM.toString(live));
        } else {
            _fail(field, string.concat("declared ", VM.toString(declared), " but chain says ", VM.toString(live)));
        }
    }

    function _checkSet(string memory field, address[] memory declared, address[] memory live) private {
        if (RolesProbes.sameSet(declared, live)) {
            _pass(field, string.concat(VM.toString(live.length), " member(s), sets match"));
        } else {
            _fail(
                field,
                string.concat(
                    "declared ",
                    VM.toString(declared.length),
                    " member(s) but chain has ",
                    VM.toString(live.length),
                    " (or membership differs)"
                )
            );
        }
    }

    // ---------------------------------------------------------------- token (template-dispatched)

    function _auditToken(string memory json, address token) private {
        if (!VM.keyExistsJson(json, ".roles.token.type")) {
            _fail("token.type", "not declared - the token block dispatches on it (crosschain|burnmint|factory|byo)");
            return;
        }
        RolesProbes.TokenTemplate declared = RolesProbes.templateFromName(VM.parseJsonString(json, ".roles.token.type"));
        RolesProbes.TokenTemplate live = RolesProbes.detectTemplate(token);

        if (declared == RolesProbes.TokenTemplate.BYO) {
            // BYO never assumes a template: only the universal admin points are point-checked.
            _pass("token.type", "byo (declaration-backed point-checks only)");
        } else if (live == declared) {
            _pass("token.type", RolesProbes.templateName(live));
        } else {
            _fail(
                "token.type",
                string.concat(
                    "declared ",
                    RolesProbes.templateName(declared),
                    " but the token surface probes as ",
                    RolesProbes.templateName(live)
                )
            );
            return; // every following token rung dispatches on the type - do not cascade noise
        }

        _auditTokenAdminPoint(json, token, declared);
        _auditCcipAdmin(json, token);

        if (declared == RolesProbes.TokenTemplate.CrossChainToken) {
            _auditHolders(
                json,
                token,
                declared,
                "burnMintRoleAdmins",
                "",
                "",
                RolesProbes.roleIdOrDefault(token, "BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE)
            );
        }

        bool hasProbeableRoles = declared != RolesProbes.TokenTemplate.BYO || _hasAcl(token);
        if (hasProbeableRoles) {
            _auditHolders(
                json,
                token,
                declared,
                "minters",
                "getMinters()",
                "isMinter(address)",
                RolesProbes.roleIdOrDefault(token, "MINTER_ROLE()", RolesProbes.MINTER_ROLE)
            );
            _auditHolders(
                json,
                token,
                declared,
                "burners",
                "getBurners()",
                "isBurner(address)",
                RolesProbes.roleIdOrDefault(token, "BURNER_ROLE()", RolesProbes.BURNER_ROLE)
            );
        } else {
            _skip("token.minters/burners", "byo token with no probeable role surface - not verifiable by read");
        }
    }

    /// @dev The template's TOP-LEVEL admin point: single-holder `defaultAdmin()` (crosschain),
    /// multi-holder `defaultAdmins{}` point-checks (burnmint), `owner()` (factory), or whichever
    /// universal point(s) the declaration carries (byo).
    function _auditTokenAdminPoint(string memory json, address token, RolesProbes.TokenTemplate t) private {
        if (t == RolesProbes.TokenTemplate.CrossChainToken) {
            if (VM.keyExistsJson(json, ".roles.token.defaultAdmin")) {
                (, address live) = RolesProbes.tryAddress(token, "defaultAdmin()");
                _checkAddress("token.defaultAdmin", VM.parseJsonAddress(json, ".roles.token.defaultAdmin"), live);
            } else {
                _skip("token.defaultAdmin", "not declared");
            }
            (, address pending) = RolesProbes.tryAddress(token, "pendingDefaultAdmin()");
            address declaredPending = VM.keyExistsJson(json, ".roles.token.pendingDefaultAdmin")
                ? VM.parseJsonAddress(json, ".roles.token.pendingDefaultAdmin")
                : address(0);
            if (pending == declaredPending) {
                if (pending != address(0)) {
                    _warn(
                        "token.pendingDefaultAdmin",
                        string.concat(
                            VM.toString(pending), " - a default-admin transfer is IN FLIGHT (accept or cancel it)"
                        )
                    );
                } else {
                    _pass("token.pendingDefaultAdmin", "none (no transfer in flight)");
                }
            } else {
                _fail(
                    "token.pendingDefaultAdmin",
                    string.concat("declared ", VM.toString(declaredPending), " but chain says ", VM.toString(pending))
                );
            }
            return;
        }
        if (t == RolesProbes.TokenTemplate.BurnMintERC20) {
            _auditHolders(json, token, t, "defaultAdmins", "", "", RolesProbes.DEFAULT_ADMIN_ROLE);
            return;
        }
        if (t == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            if (VM.keyExistsJson(json, ".roles.token.owner")) {
                (, address live) = RolesProbes.tryAddress(token, "owner()");
                _checkAddress("token.owner", VM.parseJsonAddress(json, ".roles.token.owner"), live);
            } else {
                _skip("token.owner", "not declared");
            }
            return;
        }
        // BYO: verify whichever universal admin point(s) the declaration carries.
        bool any = false;
        if (VM.keyExistsJson(json, ".roles.token.owner")) {
            (bool has, address live) = RolesProbes.tryAddress(token, "owner()");
            if (has) _checkAddress("token.owner", VM.parseJsonAddress(json, ".roles.token.owner"), live);
            else _fail("token.owner", "declared but the token exposes no owner()");
            any = true;
        }
        if (VM.keyExistsJson(json, ".roles.token.defaultAdmins")) {
            _auditHolders(json, token, t, "defaultAdmins", "", "", RolesProbes.DEFAULT_ADMIN_ROLE);
            any = true;
        }
        if (!any) {
            _warn("token", "byo token declares no admin point (owner/defaultAdmins) - only ccipAdmin/TAR anchor it");
        }
    }

    function _auditCcipAdmin(string memory json, address token) private {
        if (VM.keyExistsJson(json, ".roles.token.ccipAdmin")) {
            (bool has, address ccipAdmin) = RolesProbes.tryAddress(token, "getCCIPAdmin()");
            if (has) {
                _checkAddress("token.ccipAdmin", VM.parseJsonAddress(json, ".roles.token.ccipAdmin"), ccipAdmin);
            } else {
                _fail("token.ccipAdmin", "declared but the token exposes no getCCIPAdmin()");
            }
        } else {
            _skip("token.ccipAdmin", "not declared (token may not expose getCCIPAdmin)");
        }
    }

    function _hasAcl(address token) private view returns (bool) {
        (bool hasAcl,) = RolesProbes.tryBytes32(token, "DEFAULT_ADMIN_ROLE()");
        return hasAcl;
    }

    function _auditHolders(
        string memory json,
        address token,
        RolesProbes.TokenTemplate t,
        string memory label,
        string memory ownableGetterSig,
        string memory ownableIsSig,
        bytes32 role
    ) private {
        string memory base = string.concat(".roles.token.", label);
        if (!VM.keyExistsJson(json, base)) {
            _skip(string.concat("token.", label), "not declared");
            return;
        }
        address[] memory declared = VM.parseJsonAddressArray(json, string.concat(base, ".holders"));
        bool declaredComplete = VM.parseJsonBool(json, string.concat(base, ".complete"));

        string memory field = string.concat("token.", label);
        (bool enumerable, address[] memory live) = RolesProbes.tryEnumerateHolders(token, ownableGetterSig, role);
        if (enumerable && declaredComplete) {
            // Live-enumerable + declared complete: a full two-sided compare detects BOTH a revoked
            // declared holder AND an undeclared (rogue) additive grant.
            _checkSet(field, declared, live);
            return;
        }
        // OPT-IN additive detection for non-enumerable AccessControl tokens (crosschain/burnmint):
        // when SCAN_FROM_BLOCK is set, two-sided-compare against the event-reconstructed live set.
        if (!enumerable && _tryAdditiveScan(field, token, t, role, declared)) return;
        // Default path: declared-holders-hold + the honesty boundary (no silent CLEAN over additive).
        _auditDeclaredHold(field, token, t, ownableIsSig, role, declared);
        if (!enumerable) _warnNonEnumerable(field, t, declaredComplete);
    }

    /// @dev Returns true when SCAN_FROM_BLOCK drove a full two-sided compare (result already reported).
    function _tryAdditiveScan(
        string memory field,
        address token,
        RolesProbes.TokenTemplate t,
        bytes32 role,
        address[] memory declared
    ) private returns (bool handled) {
        if (t != RolesProbes.TokenTemplate.CrossChainToken && t != RolesProbes.TokenTemplate.BurnMintERC20) {
            return false;
        }
        uint256 fromBlock = VM.envOr("SCAN_FROM_BLOCK", uint256(0));
        if (fromBlock == 0) return false;
        try this.scanLiveHolders(token, role, fromBlock) returns (address[] memory scanned) {
            _checkSet(field, declared, scanned);
            return true;
        } catch {
            _warn(
                field,
                "SCAN_FROM_BLOCK set but eth_getLogs failed over the range - fell back to declared-holders-hold (additive grants NOT verified)"
            );
            return false;
        }
    }

    /// @dev Verify every DECLARED holder still holds the role (a revoked declared holder FAILs). Does
    /// NOT detect an undeclared additive grant on a non-enumerable token - the caller WARNs about that.
    function _auditDeclaredHold(
        string memory field,
        address token,
        RolesProbes.TokenTemplate t,
        string memory ownableIsSig,
        bytes32 role,
        address[] memory declared
    ) private {
        bool useOwnableSet = t == RolesProbes.TokenTemplate.FactoryBurnMintERC20 && bytes(ownableIsSig).length != 0;
        uint256 bad = 0;
        for (uint256 i = 0; i < declared.length; i++) {
            bool member = useOwnableSet
                ? RolesProbes.isInOwnableSet(token, ownableIsSig, declared[i])
                : RolesProbes.hasRole(token, role, declared[i]);
            if (!member) {
                _fail(field, string.concat("declared holder ", VM.toString(declared[i]), " does NOT hold the role"));
                bad++;
            }
        }
        if (bad == 0) {
            _pass(field, string.concat("all ", VM.toString(declared.length), " declared holder(s) hold the role"));
        }
    }

    /// @dev The honesty boundary: on a non-enumerable token, declared-holders-hold does NOT prove the
    /// absence of an undeclared additive grant. WARN whether the list is complete:false (candidate
    /// seed) OR complete:true (a PAST snapshot proof, not re-verifiable by read now) - never silent CLEAN.
    function _warnNonEnumerable(string memory field, RolesProbes.TokenTemplate t, bool declaredComplete) private {
        if (declaredComplete) {
            _warn(
                field,
                "complete:true is a past snapshot proof, NOT re-verifiable by read - a grant since the snapshot is undetected. Re-run roles-check with SCAN_FROM_BLOCK to two-sided-compare"
            );
        } else if (t == RolesProbes.TokenTemplate.BYO) {
            _warn(
                field,
                "complete:false - a byo token's internal roles are never provable by read; additive grants undetected"
            );
        } else {
            _warn(
                field,
                "complete:false (candidate seed) - additive grants undetected; run roles-check (or snapshot-chain) with SCAN_FROM_BLOCK to enumerate via RoleGranted/RoleRevoked events"
            );
        }
    }

    /// @notice External for try/catch: reconstruct the live holders of `role` from the token's
    /// RoleGranted/RoleRevoked events over [fromBlock, latest] (the reconcile-time analog of the
    /// snapshot's scan). Kept identical in shape to `RolesSnapshot.scanRoleMembers`; the caller then
    /// two-sided-compares the result against the declared list. External so a log-range failure is
    /// catchable and degrades to a WARN rather than aborting the audit.
    function scanLiveHolders(address token, bytes32 role, uint256 fromBlock) external returns (address[] memory) {
        bytes32[] memory topics = new bytes32[](2);
        topics[1] = role;
        topics[0] = keccak256("RoleGranted(bytes32,address,address)");
        Vm.EthGetLogs[] memory granted = VM.eth_getLogs(fromBlock, block.number, token, topics);
        topics[0] = keccak256("RoleRevoked(bytes32,address,address)");
        Vm.EthGetLogs[] memory revoked = VM.eth_getLogs(fromBlock, block.number, token, topics);
        // A holder is live iff it was granted and holds the role now (a revoke, or a later re-grant, is
        // reconciled by the final hasRole check - cheaper and exact than replaying grant/revoke order).
        address[] memory candidates = new address[](granted.length);
        uint256 n = 0;
        for (uint256 i = 0; i < granted.length; i++) {
            address who = address(uint160(uint256(granted[i].topics[2])));
            if (!RolesProbes.contains(_shrink(candidates, n), who) && RolesProbes.hasRole(token, role, who)) {
                candidates[n++] = who;
            }
        }
        // silence unused-variable lint: revoked is implicitly handled by the hasRole recheck above
        revoked;
        assembly {
            mstore(candidates, n)
        }
        return candidates;
    }

    function _shrink(address[] memory arr, uint256 n) private pure returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = arr[i];
        }
    }

    // ---------------------------------------------------------------- TAR

    function _auditTar(string memory json, address token) private {
        if (!VM.keyExistsJson(json, ".roles.tokenAdminRegistry")) {
            _skip("tokenAdminRegistry", "no tokenAdminRegistry block declared");
            return;
        }
        address tar = VM.parseJsonAddress(json, ".roles.tokenAdminRegistry.registry");
        (bool s, bytes memory ret) = tar.staticcall(abi.encodeWithSignature("getTokenConfig(address)", token));
        if (!s || ret.length < 96) {
            _fail("tokenAdminRegistry.registry", string.concat(VM.toString(tar), " does not answer getTokenConfig"));
            return;
        }
        (address admin, address pending,) = abi.decode(ret, (address, address, address));
        _checkAddress(
            "tokenAdminRegistry.administrator",
            VM.parseJsonAddress(json, ".roles.tokenAdminRegistry.administrator"),
            admin
        );
        if (VM.keyExistsJson(json, ".roles.tokenAdminRegistry.pendingAdministrator")) {
            _checkAddress(
                "tokenAdminRegistry.pendingAdministrator",
                VM.parseJsonAddress(json, ".roles.tokenAdminRegistry.pendingAdministrator"),
                pending
            );
        } else if (pending != address(0)) {
            _warn(
                "tokenAdminRegistry.pendingAdministrator",
                string.concat(VM.toString(pending), " - an admin transfer is IN FLIGHT (accept or cancel it)")
            );
        }
        // The TAR contract's own owner() is the network operator's authority - deliberately not audited.
    }

    // ---------------------------------------------------------------- pool

    function _auditPool(string memory json, address pool) private {
        (bool isV2,, address rateLimitAdmin, address feeAdmin) = RolesProbes.readPoolAdmins(pool);
        (, address owner_) = RolesProbes.tryAddress(pool, "owner()");
        if (VM.keyExistsJson(json, ".roles.pool.owner")) {
            _checkAddress("pool.owner", VM.parseJsonAddress(json, ".roles.pool.owner"), owner_);
        } else {
            _skip("pool.owner", "not declared");
        }
        if (VM.keyExistsJson(json, ".roles.pool.rateLimitAdmin")) {
            _checkAddress(
                "pool.rateLimitAdmin", VM.parseJsonAddress(json, ".roles.pool.rateLimitAdmin"), rateLimitAdmin
            );
        } else {
            // Governance-critical slot: an undeclared one is a visible SKIP, never a silent CLEAN.
            _skip("pool.rateLimitAdmin", "not declared - run snapshot-chain to backfill it");
        }
        if (VM.keyExistsJson(json, ".roles.pool.feeAdmin")) {
            if (isV2) {
                _checkAddress("pool.feeAdmin", VM.parseJsonAddress(json, ".roles.pool.feeAdmin"), feeAdmin);
            } else {
                _fail("pool.feeAdmin", "declared, but the pool is v1.x (no feeAdmin surface)");
            }
        } else if (!isV2) {
            _skip("pool.feeAdmin", "v1.x pool has no feeAdmin");
        } else {
            _skip("pool.feeAdmin", "not declared (v2 pool) - run snapshot-chain to backfill it");
        }
        if (VM.keyExistsJson(json, ".roles.pool.hooks")) {
            if (isV2) {
                (, address hooks) = RolesProbes.tryAddress(pool, "getAdvancedPoolHooks()");
                _checkAddress("pool.hooks", VM.parseJsonAddress(json, ".roles.pool.hooks"), hooks);
            } else {
                _fail("pool.hooks", "declared, but the pool is v1.x (no AdvancedPoolHooks surface)");
            }
        }
    }

    // ---------------------------------------------------------------- lockbox / hooks / rebalancer

    function _auditLockbox(string memory json, address pool) private {
        if (!VM.keyExistsJson(json, ".roles.lockbox")) {
            _skip("lockbox", "no lockbox block declared (burnmint chain)");
            return;
        }
        address declared = VM.parseJsonAddress(json, ".roles.lockbox.address");
        (bool has, address live) = RolesProbes.tryAddress(pool, "getLockBox()");
        if (has) _checkAddress("lockbox.address", declared, live);
        (, address owner_) = RolesProbes.tryAddress(declared, "owner()");
        _checkAddress("lockbox.owner", VM.parseJsonAddress(json, ".roles.lockbox.owner"), owner_);
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(declared, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        _checkSet(
            "lockbox.authorizedCallers", VM.parseJsonAddressArray(json, ".roles.lockbox.authorizedCallers"), callers
        );
    }

    function _auditHooks(string memory json) private {
        if (!VM.keyExistsJson(json, ".roles.hooks")) {
            _skip("hooks", "no hooks block declared");
            return;
        }
        address hooks = VM.parseJsonAddress(json, ".roles.hooks.address");
        (, address owner_) = RolesProbes.tryAddress(hooks, "owner()");
        _checkAddress("hooks.owner", VM.parseJsonAddress(json, ".roles.hooks.owner"), owner_);
        (, bool allowlistEnabled) = RolesProbes.tryBool(hooks, "getAllowListEnabled()");
        bool declaredEnabled = VM.parseJsonBool(json, ".roles.hooks.allowlistEnabled");
        if (declaredEnabled == allowlistEnabled) {
            _pass("hooks.allowlistEnabled", allowlistEnabled ? "true (IMMUTABLE - set at deploy)" : "false");
        } else {
            _fail(
                "hooks.allowlistEnabled",
                string.concat(
                    "declared ",
                    declaredEnabled ? "true" : "false",
                    " but chain says ",
                    allowlistEnabled ? "true" : "false",
                    " (i_allowlistEnabled is immutable - fix the declaration)"
                )
            );
        }
        (, address[] memory allowlist) = RolesProbes.tryAddressArray(hooks, abi.encodeWithSignature("getAllowList()"));
        _checkSet("hooks.allowlist", VM.parseJsonAddressArray(json, ".roles.hooks.allowlist"), allowlist);
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(hooks, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        _checkSet("hooks.authorizedCallers", VM.parseJsonAddressArray(json, ".roles.hooks.authorizedCallers"), callers);
        if (VM.keyExistsJson(json, ".roles.hooks.policyEngine")) {
            (, address engine) = RolesProbes.tryAddress(hooks, "getPolicyEngine()");
            _checkAddress("hooks.policyEngine", VM.parseJsonAddress(json, ".roles.hooks.policyEngine"), engine);
        }
    }

    function _auditRebalancer(string memory json, address pool) private {
        if (!VM.keyExistsJson(json, ".roles.rebalancer")) {
            _skip("rebalancer", "not declared (v1 LockRelease pools only)");
            return;
        }
        (bool has, address live) = RolesProbes.tryAddress(pool, "getRebalancer()");
        if (!has) {
            _fail("rebalancer", "declared, but the pool exposes no getRebalancer() (v2 LR pools use the lockbox)");
            return;
        }
        _checkAddress("rebalancer", VM.parseJsonAddress(json, ".roles.rebalancer"), live);
    }

    // ---------------------------------------------------------------- governance (OPTIONAL, three shapes)

    function _auditGovernance(string memory json) private {
        bool hasSafe = VM.keyExistsJson(json, ".roles.governance.safe");
        bool hasTimelock = VM.keyExistsJson(json, ".roles.governance.timelock");
        if (!hasSafe && !hasTimelock) {
            _skip("governance", "no governance{} declared (EOA-only chain) - valid, nothing to reconcile");
            return;
        }
        address safe = address(0);
        if (hasSafe) safe = _auditSafe(json);
        if (hasTimelock) _auditTimelock(json, hasSafe, safe);
        else _skip("governance.timelock", "not declared (safe-only shape)");
        if (!hasSafe) _skip("governance.safe", "not declared (timelock-only shape; an EOA proposer is valid)");

        // cross-consistency: the emergency-throttle convention (WARN, never FAIL - it is a convention)
        if (hasSafe && VM.keyExistsJson(json, ".roles.pool.rateLimitAdmin")) {
            address rla = VM.parseJsonAddress(json, ".roles.pool.rateLimitAdmin");
            if (rla != safe) {
                _warn(
                    "pool.rateLimitAdmin",
                    string.concat(
                        "declared ",
                        VM.toString(rla),
                        " != governance.safe ",
                        VM.toString(safe),
                        " - convention: rateLimitAdmin stays on the Safe (fast emergency throttle)"
                    )
                );
            } else {
                _pass("pool.rateLimitAdmin", "== governance.safe (emergency-throttle convention honored)");
            }
        }
    }

    function _auditSafe(string memory json) private returns (address safe) {
        safe = VM.parseJsonAddress(json, ".roles.governance.safe.address");
        if (safe.code.length == 0) {
            _fail("governance.safe.address", string.concat(VM.toString(safe), " has NO code on this chain"));
            return safe;
        }
        _pass("governance.safe.address", string.concat(VM.toString(safe), " (has code)"));
        if (VM.keyExistsJson(json, ".roles.governance.safe.threshold")) {
            uint256 declared = VM.parseJsonUint(json, ".roles.governance.safe.threshold");
            (, uint256 live) = RolesProbes.tryUint(safe, "getThreshold()");
            if (declared == live) {
                _pass("governance.safe.threshold", VM.toString(live));
            } else {
                _fail(
                    "governance.safe.threshold",
                    string.concat("declared ", VM.toString(declared), " but chain says ", VM.toString(live))
                );
            }
        }
        if (VM.keyExistsJson(json, ".roles.governance.safe.owners")) {
            (, address[] memory owners) = RolesProbes.tryAddressArray(safe, abi.encodeWithSignature("getOwners()"));
            _checkSet("governance.safe.owners", VM.parseJsonAddressArray(json, ".roles.governance.safe.owners"), owners);
        }
    }

    function _auditTimelock(string memory json, bool hasSafe, address safe) private {
        address tl = VM.parseJsonAddress(json, ".roles.governance.timelock.address");
        if (tl.code.length == 0) {
            _fail("governance.timelock.address", string.concat(VM.toString(tl), " has NO code on this chain"));
            return;
        }
        _pass("governance.timelock.address", string.concat(VM.toString(tl), " (has code)"));
        if (VM.keyExistsJson(json, ".roles.governance.timelock.minDelay")) {
            uint256 declared = VM.parseJsonUint(json, ".roles.governance.timelock.minDelay");
            (, uint256 live) = RolesProbes.tryUint(tl, "getMinDelay()");
            if (declared == live) {
                _pass("governance.timelock.minDelay", VM.toString(live));
            } else {
                _fail(
                    "governance.timelock.minDelay",
                    string.concat("declared ", VM.toString(declared), " but chain says ", VM.toString(live))
                );
            }
        }
        address[] memory proposers = _auditTimelockRole(json, tl, "proposers", RolesProbes.TIMELOCK_PROPOSER_ROLE);
        _auditTimelockRole(json, tl, "cancellers", RolesProbes.TIMELOCK_CANCELLER_ROLE);
        _auditTimelockRole(json, tl, "executors", RolesProbes.TIMELOCK_EXECUTOR_ROLE);

        // safe+timelock shape: the proposer is TYPICALLY the safe - a disagreement is a WARN, never a
        // FAIL (timelock-only shape with an EOA proposer is valid and never reaches this branch).
        if (hasSafe && proposers.length > 0 && !RolesProbes.contains(proposers, safe)) {
            _warn(
                "governance.timelock.proposers",
                string.concat("declared proposers do not include governance.safe ", VM.toString(safe))
            );
        }

        if (
            VM.keyExistsJson(json, ".roles.governance.timelock.adminRenounced")
                && VM.parseJsonBool(json, ".roles.governance.timelock.adminRenounced")
        ) {
            // Non-enumerable AccessControl: verify no DECLARED governance address still holds the
            // timelock's DEFAULT_ADMIN_ROLE (self-administration by the timelock itself is fine).
            uint256 bad = 0;
            if (hasSafe && RolesProbes.hasRole(tl, RolesProbes.DEFAULT_ADMIN_ROLE, safe)) {
                _fail("governance.timelock.adminRenounced", "governance.safe still holds DEFAULT_ADMIN_ROLE");
                bad++;
            }
            for (uint256 i = 0; i < proposers.length; i++) {
                if (proposers[i] != tl && RolesProbes.hasRole(tl, RolesProbes.DEFAULT_ADMIN_ROLE, proposers[i])) {
                    _fail(
                        "governance.timelock.adminRenounced",
                        string.concat("proposer ", VM.toString(proposers[i]), " still holds DEFAULT_ADMIN_ROLE")
                    );
                    bad++;
                }
            }
            if (bad == 0) _pass("governance.timelock.adminRenounced", "no declared governance address holds admin");
        }
    }

    function _auditTimelockRole(string memory json, address tl, string memory label, bytes32 role)
        private
        returns (address[] memory declared)
    {
        string memory path = string.concat(".roles.governance.timelock.", label);
        if (!VM.keyExistsJson(json, path)) {
            _skip(string.concat("governance.timelock.", label), "not declared");
            return new address[](0);
        }
        declared = VM.parseJsonAddressArray(json, path);
        uint256 bad = 0;
        for (uint256 i = 0; i < declared.length; i++) {
            if (!RolesProbes.hasRole(tl, role, declared[i])) {
                _fail(
                    string.concat("governance.timelock.", label),
                    string.concat("declared ", VM.toString(declared[i]), " does NOT hold the role")
                );
                bad++;
            }
        }
        if (bad == 0) {
            _pass(
                string.concat("governance.timelock.", label),
                string.concat("all ", VM.toString(declared.length), " declared holder(s) hold the role")
            );
        }
    }
}
