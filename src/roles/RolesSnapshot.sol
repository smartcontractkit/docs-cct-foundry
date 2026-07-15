// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {RolesProbes} from "./RolesProbes.sol";
import {RegistryWriter} from "../utils/RegistryWriter.sol";
import {ProjectStore} from "../utils/ProjectStore.sol";

/// @title RolesSnapshot
/// @notice Builds the `roles{}` subtree of `project/<selectorName>.json` FROM the live chain (the active
/// fork must be the chain itself) — the bootstrap half of the authority durable store: `make
/// snapshot-chain` backfills declared state from chain, `make roles-check` reconciles it forever after.
/// Preserve-and-replace: chain-readable values are re-read live; pure DECLARATIONS that cannot be
/// enumerated on-chain (timelock proposer/canceller/executor lists, `adminRenounced`) are carried over
/// from the existing `roles{}` block verbatim.
/// @dev HONESTY RULE (never fabricate): on a non-enumerable AccessControl token every role-holder list
/// (minters, burners, `burnMintRoleAdmins`, plain-AccessControl `defaultAdmins`) is seeded from KNOWN
/// CANDIDATES (pool, pool owner, TAR administrator, ccipAdmin, the top-level admin + previously
/// declared holders) and marked `"complete": false` — it is only marked complete when the token
/// enumerates its holders OR a `RoleGranted`/`RoleRevoked` event scan ran (`SCAN_FROM_BLOCK=<block>`
/// env + an RPC that serves `eth_getLogs` over the range). A skipped scan is logged, never silently
/// presented as a full list.
contract RolesSnapshot {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant ROLE_GRANTED_TOPIC = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 private constant ROLE_REVOKED_TOPIC = keccak256("RoleRevoked(bytes32,address,address)");

    /// @dev Resolved chain facts threaded through the block builders (a struct keeps `build` below
    /// the stack-depth limit).
    struct Ctx {
        string name;
        address token;
        address pool;
        address tar;
        address poolOwner;
        address tarAdmin;
        bool isV2;
        address rateLimitAdmin;
        address feeAdmin;
        address ccipAdmin;
        address adminHolder; // defaultAdmin (crosschain) / owner (factory) / first found admin (byo)
        RolesProbes.TokenTemplate template;
    }

    /// @notice Build the `roles{}` JSON for `name` (the selectorName) from the ACTIVE fork.
    /// `configJson` is `config/chains/<name>.json` (pure API/chain facts — the `.ccip.tokenAdminRegistry`
    /// directory fallback); `projectJson` is `project/<name>.json` (the existing `.roles{}` block —
    /// self-embedded token/pool anchors + preserved declarations). The two writer-domains stay separate.
    function build(string memory name, string memory configJson, string memory projectJson)
        external
        returns (string memory)
    {
        Ctx memory c;
        c.name = name;
        (c.token, c.pool) = _resolveProject(name, projectJson);
        address ccipTar = VM.keyExistsJson(configJson, ".ccip.tokenAdminRegistry")
            ? VM.parseJsonAddress(configJson, ".ccip.tokenAdminRegistry")
            : address(0);
        c.tar = _resolveTar(projectJson, ccipTar);
        c.template = RolesProbes.detectTemplate(c.token);
        (c.isV2,, c.rateLimitAdmin, c.feeAdmin) = RolesProbes.readPoolAdmins(c.pool);
        (, c.poolOwner) = RolesProbes.tryAddress(c.pool, "owner()");
        (c.tarAdmin,) = _tarConfig(c.tar, c.token);
        return _assemble(c, projectJson);
    }

    /// @dev Token/pool resolution — the declared `roles{}` wins (it IS the durable record; the
    /// `project/<selectorName>.json` `addresses{}` store is single-valued per role and, in this repo,
    /// gitignored), then the `TOKEN`/`TOKEN_POOL` env overrides, then the store's active pointers.
    function _resolveProject(string memory name, string memory json)
        private
        view
        returns (address token, address pool)
    {
        if (VM.keyExistsJson(json, ".roles.token.address")) {
            token = VM.parseJsonAddress(json, ".roles.token.address");
        }
        if (token == address(0)) token = VM.envOr("TOKEN", address(0));
        if (token == address(0)) token = RegistryWriter.read(name, "token");
        require(
            token != address(0),
            string.concat(
                "[snapshot] no token to snapshot: declare roles.token.address, set TOKEN=<addr>, or deploy first (",
                ProjectStore.display(name),
                " addresses.active.token)"
            )
        );
        if (VM.keyExistsJson(json, ".roles.pool.address")) {
            pool = VM.parseJsonAddress(json, ".roles.pool.address");
        }
        if (pool == address(0)) pool = VM.envOr("TOKEN_POOL", address(0));
        if (pool == address(0)) pool = RegistryWriter.read(name, "tokenPool");
        require(
            pool != address(0),
            string.concat(
                "[snapshot] no pool to snapshot: declare roles.pool.address, set TOKEN_POOL=<addr>, or deploy first (",
                ProjectStore.display(name),
                " addresses.active.tokenPool)"
            )
        );
    }

    function _assemble(Ctx memory c, string memory json) private returns (string memory) {
        string memory root = string.concat("roles-", c.name);
        VM.serializeString(root, "token", _tokenBlock(c, json));
        VM.serializeString(root, "tokenAdminRegistry", _tarBlock(c));

        string memory sub = _lockboxBlock(c.name, c.pool);
        if (bytes(sub).length != 0) VM.serializeString(root, "lockbox", sub);

        sub = _hooksBlock(c.name, json, c.pool, c.isV2);
        if (bytes(sub).length != 0) VM.serializeString(root, "hooks", sub);

        (bool hasRebalancer, address rebalancer) = RolesProbes.tryAddress(c.pool, "getRebalancer()");
        if (hasRebalancer) VM.serializeAddress(root, "rebalancer", rebalancer);

        sub = _governanceBlock(c.name, json, c.poolOwner);
        if (bytes(sub).length != 0) VM.serializeString(root, "governance", sub);

        // pool is serialized last so the mandatory key closes the object
        return VM.serializeString(root, "pool", _poolBlock(c));
    }

    // ---------------------------------------------------------------- token (template-dispatched)

    function _tokenBlock(Ctx memory c, string memory json) private returns (string memory) {
        string memory obj = string.concat("roles-token-", c.name);
        VM.serializeString(obj, "type", RolesProbes.templateName(c.template));

        (bool hasCcipAdmin, address ccipAdmin) = RolesProbes.tryAddress(c.token, "getCCIPAdmin()");
        c.ccipAdmin = ccipAdmin;
        if (hasCcipAdmin) VM.serializeAddress(obj, "ccipAdmin", ccipAdmin);

        if (c.template == RolesProbes.TokenTemplate.CrossChainToken) {
            _tokenAdminCrossChain(c, json, obj);
        } else if (c.template == RolesProbes.TokenTemplate.BurnMintERC20) {
            c.adminHolder = _firstAdminCandidate(c, json);
            VM.serializeString(obj, "defaultAdmins", _defaultAdminsBlock(c, json));
        } else if (c.template == RolesProbes.TokenTemplate.FactoryBurnMintERC20) {
            (, c.adminHolder) = RolesProbes.tryAddress(c.token, "owner()");
            VM.serializeAddress(obj, "owner", c.adminHolder);
        } else {
            _tokenAdminByo(c, json, obj);
        }

        if (c.template != RolesProbes.TokenTemplate.BYO || _hasAclSurface(c.token)) {
            VM.serializeString(obj, "minters", _mintBurnBlock(c, json, true));
            VM.serializeString(obj, "burners", _mintBurnBlock(c, json, false));
        } else {
            console.log(
                "[snapshot] SKIP token.minters/burners: BYO token exposes no probeable role surface - "
                "token-internal authority stays undeclared (complete coverage is not claimable)"
            );
        }
        return VM.serializeAddress(obj, "address", c.token);
    }

    /// @dev CrossChainToken admin surface: the single-holder two-step default admin + the separate
    /// `BURN_MINT_ADMIN_ROLE` that admins MINTER/BURNER — NOT moved by a defaultAdmin transfer.
    function _tokenAdminCrossChain(Ctx memory c, string memory json, string memory obj) private {
        (, c.adminHolder) = RolesProbes.tryAddress(c.token, "defaultAdmin()");
        VM.serializeAddress(obj, "defaultAdmin", c.adminHolder);
        (, address pending) = RolesProbes.tryAddress(c.token, "pendingDefaultAdmin()");
        if (pending != address(0)) VM.serializeAddress(obj, "pendingDefaultAdmin", pending);
        bytes32 role = RolesProbes.roleIdOrDefault(c.token, "BURN_MINT_ADMIN_ROLE()", RolesProbes.BURN_MINT_ADMIN_ROLE);
        address[] memory candidates = _candidates(c, json, ".roles.token.burnMintRoleAdmins.holders");
        VM.serializeString(obj, "burnMintRoleAdmins", _holdersBlock(c, "burnMintRoleAdmins", "", role, candidates));
    }

    /// @dev BYO admin surface: probe the three universal admin-registration points; declare only
    /// what answers (`owner()`, `getCCIPAdmin()` — handled by the caller — and OZ AccessControl).
    function _tokenAdminByo(Ctx memory c, string memory json, string memory obj) private {
        (bool hasOwner, address owner_) = RolesProbes.tryAddress(c.token, "owner()");
        if (hasOwner) {
            c.adminHolder = owner_;
            VM.serializeAddress(obj, "owner", owner_);
        }
        if (_hasAclSurface(c.token)) {
            if (c.adminHolder == address(0)) c.adminHolder = _firstAdminCandidate(c, json);
            VM.serializeString(obj, "defaultAdmins", _defaultAdminsBlock(c, json));
        }
    }

    function _defaultAdminsBlock(Ctx memory c, string memory json) private returns (string memory) {
        address[] memory candidates = _candidates(c, json, ".roles.token.defaultAdmins.holders");
        return _holdersBlock(c, "defaultAdmins", "", RolesProbes.DEFAULT_ADMIN_ROLE, candidates);
    }

    /// @dev First candidate that holds DEFAULT_ADMIN_ROLE on a plain-AccessControl token (no
    /// single-holder getter exists there — multi-holder by design).
    function _firstAdminCandidate(Ctx memory c, string memory json) private view returns (address) {
        address[] memory candidates = _candidates(c, json, ".roles.token.defaultAdmins.holders");
        for (uint256 i = 0; i < candidates.length; i++) {
            if (RolesProbes.hasRole(c.token, RolesProbes.DEFAULT_ADMIN_ROLE, candidates[i])) {
                return candidates[i];
            }
        }
        console.log("[snapshot] WARN token.defaultAdmins: no known candidate holds DEFAULT_ADMIN_ROLE");
        return address(0);
    }

    function _hasAclSurface(address token) private view returns (bool) {
        (bool hasAcl,) = RolesProbes.tryBytes32(token, "DEFAULT_ADMIN_ROLE()");
        return hasAcl;
    }

    function _mintBurnBlock(Ctx memory c, string memory json, bool minters) private returns (string memory) {
        if (minters) {
            return _holdersBlock(
                c,
                "minters",
                "getMinters()",
                RolesProbes.roleIdOrDefault(c.token, "MINTER_ROLE()", RolesProbes.MINTER_ROLE),
                _candidates(c, json, ".roles.token.minters.holders")
            );
        }
        return _holdersBlock(
            c,
            "burners",
            "getBurners()",
            RolesProbes.roleIdOrDefault(c.token, "BURNER_ROLE()", RolesProbes.BURNER_ROLE),
            _candidates(c, json, ".roles.token.burners.holders")
        );
    }

    /// @dev One role-holder block: enumerable -> complete; event scan (SCAN_FROM_BLOCK) -> complete;
    /// candidate membership checks -> `"complete": false` (+ a logged SKIP naming what was skipped).
    /// A BYO token never gets `complete: true` — its deploy block is unknowable here, so no scan
    /// range can be proven to cover the token's whole history; BYO token-internal lists stay
    /// declaration-backed and `complete: false` (the honest-coverage rule).
    function _holdersBlock(
        Ctx memory c,
        string memory label,
        string memory ownableGetterSig,
        bytes32 role,
        address[] memory candidates
    ) private returns (string memory) {
        address token = c.token;
        // Ownable membership getter, derived from the list (authoritative), NOT re-derived from the
        // role id downstream (which may be a token's custom MINTER_ROLE()): getMinters()->isMinter, etc.
        string memory ownableIsSig = keccak256(bytes(ownableGetterSig)) == keccak256(bytes("getMinters()"))
            ? "isMinter(address)"
            : keccak256(bytes(ownableGetterSig)) == keccak256(bytes("getBurners()")) ? "isBurner(address)" : "";
        uint256 scannedFrom = 0;
        (bool complete, address[] memory holders) = RolesProbes.tryEnumerateHolders(token, ownableGetterSig, role);
        if (!complete) {
            uint256 fromBlock = VM.envOr("SCAN_FROM_BLOCK", uint256(0));
            if (fromBlock != 0 && c.template != RolesProbes.TokenTemplate.BYO) {
                try this.scanRoleMembers(token, role, fromBlock) returns (address[] memory scanned) {
                    holders = _filterHolders(token, ownableIsSig, role, _union(scanned, candidates));
                    complete = true;
                    scannedFrom = fromBlock;
                    console.log(
                        string.concat(
                            "[snapshot] ",
                            label,
                            ": event scan ran from block ",
                            VM.toString(fromBlock),
                            " - list marked complete"
                        )
                    );
                } catch {
                    console.log(
                        string.concat(
                            "[snapshot] SKIP ",
                            label,
                            " event scan (eth_getLogs failed over the range) - falling back to candidates"
                        )
                    );
                }
            } else if (fromBlock == 0) {
                console.log(
                    string.concat(
                        "[snapshot] SKIP ",
                        label,
                        " event scan (SCAN_FROM_BLOCK unset) - candidate seed only, marked complete:false"
                    )
                );
            } else {
                console.log(
                    string.concat("[snapshot] ", label, ": BYO token - declaration-backed only, complete:false")
                );
            }
            if (!complete) holders = _filterHolders(token, ownableIsSig, role, candidates);
        }
        string memory obj = string.concat("roles-", label, "-", c.name);
        VM.serializeBool(obj, "complete", complete);
        // Provenance: when the list was proven by an event scan, record the block it scanned from so a
        // later reconcile knows the completeness is a proof AS OF that block (not a live invariant), and
        // an opt-in reconcile scan can resume from it. Enumerable-derived lists carry no block.
        if (scannedFrom != 0) VM.serializeUint(obj, "scannedFromBlock", scannedFrom);
        return VM.serializeAddress(obj, "holders", holders);
    }

    /// @notice External for try/catch: enumerate every account ever granted/revoked `role` via logs.
    function scanRoleMembers(address token, bytes32 role, uint256 fromBlock) external returns (address[] memory) {
        bytes32[] memory topics = new bytes32[](2);
        topics[1] = role;
        topics[0] = ROLE_GRANTED_TOPIC;
        Vm.EthGetLogs[] memory granted = VM.eth_getLogs(fromBlock, block.number, token, topics);
        topics[0] = ROLE_REVOKED_TOPIC;
        Vm.EthGetLogs[] memory revoked = VM.eth_getLogs(fromBlock, block.number, token, topics);
        address[] memory out = new address[](granted.length + revoked.length);
        uint256 n = 0;
        for (uint256 i = 0; i < granted.length; i++) {
            out[n++] = address(uint160(uint256(granted[i].topics[2])));
        }
        for (uint256 i = 0; i < revoked.length; i++) {
            out[n++] = address(uint160(uint256(revoked[i].topics[2])));
        }
        assembly {
            mstore(out, n)
        }
        return out;
    }

    /// @dev Keep only the candidates that CURRENTLY hold the role (hasRole point-check, with the
    /// Ownable `isMinter`/`isBurner` fallback when the token has no AccessControl surface). The
    /// membership getter is passed in (derived from the list, not the role id) so a token with a
    /// custom `MINTER_ROLE()` id still probes the right Ownable getter.
    function _filterHolders(address token, string memory ownableIsSig, bytes32 role, address[] memory candidates)
        private
        view
        returns (address[] memory)
    {
        bool acl = _hasAclSurface(token);
        address[] memory kept = new address[](candidates.length);
        uint256 n = 0;
        for (uint256 i = 0; i < candidates.length; i++) {
            bool member = acl
                ? RolesProbes.hasRole(token, role, candidates[i])
                : RolesProbes.isInOwnableSet(token, ownableIsSig, candidates[i]);
            if (member) kept[n++] = candidates[i];
        }
        assembly {
            mstore(kept, n)
        }
        return kept;
    }

    /// @dev Candidate seed for non-enumerable role holders: previously declared holders (a declared
    /// path pointing at an address[] or a single address) + every other authority we know about.
    function _candidates(Ctx memory c, string memory json, string memory declaredPath)
        private
        view
        returns (address[] memory)
    {
        address[] memory declared = new address[](0);
        if (VM.keyExistsJson(json, declaredPath)) {
            try this.parseDeclaredAddresses(json, declaredPath) returns (address[] memory d) {
                declared = d;
            } catch {
                try this.parseDeclaredAddress(json, declaredPath) returns (address d) {
                    declared = new address[](1);
                    declared[0] = d;
                } catch {} // solhint-disable-line no-empty-blocks
            }
        }
        address[] memory fixed_ = new address[](5);
        fixed_[0] = c.pool;
        fixed_[1] = c.poolOwner;
        fixed_[2] = c.tarAdmin;
        fixed_[3] = c.ccipAdmin;
        fixed_[4] = c.adminHolder;
        return _union(declared, fixed_);
    }

    /// @notice External for try/catch: parse a declared address[] at `path`.
    function parseDeclaredAddresses(string memory json, string memory path) external pure returns (address[] memory) {
        return VM.parseJsonAddressArray(json, path);
    }

    /// @notice External for try/catch: parse a single declared address at `path`.
    function parseDeclaredAddress(string memory json, string memory path) external pure returns (address) {
        return VM.parseJsonAddress(json, path);
    }

    function _union(address[] memory a, address[] memory b) private pure returns (address[] memory) {
        address[] memory out = new address[](a.length + b.length);
        uint256 n = 0;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != address(0) && !RolesProbes.contains(_shrink(out, n), a[i])) out[n++] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] != address(0) && !RolesProbes.contains(_shrink(out, n), b[i])) out[n++] = b[i];
        }
        assembly {
            mstore(out, n)
        }
        return out;
    }

    function _shrink(address[] memory arr, uint256 n) private pure returns (address[] memory view_) {
        view_ = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            view_[i] = arr[i];
        }
    }

    // ---------------------------------------------------------------- TAR

    /// @dev The TAR the token is REGISTERED in — can differ from the directory one (`.ccip.
    /// tokenAdminRegistry`), e.g. a project registered in a staging TAR. Resolution: declared
    /// `.roles.tokenAdminRegistry.registry` > `TAR` env > `.ccip.tokenAdminRegistry`.
    /// The TAR CONTRACT's own `owner()` (the registry-module authority) is the network operator's,
    /// deliberately out of scope — neither snapshotted nor reconciled.
    function _resolveTar(string memory projectJson, address ccipTar) private view returns (address) {
        if (VM.keyExistsJson(projectJson, ".roles.tokenAdminRegistry.registry")) {
            return VM.parseJsonAddress(projectJson, ".roles.tokenAdminRegistry.registry");
        }
        address env = VM.envOr("TAR", address(0));
        if (env != address(0)) return env;
        return ccipTar; // the directory TAR from config/chains/<name>.json .ccip.tokenAdminRegistry
    }

    function _tarConfig(address tar, address token) private view returns (address admin, address pending) {
        (bool s, bytes memory ret) = tar.staticcall(abi.encodeWithSignature("getTokenConfig(address)", token));
        if (s && ret.length >= 96) {
            (admin, pending,) = abi.decode(ret, (address, address, address));
        }
    }

    function _tarBlock(Ctx memory c) private returns (string memory) {
        (address admin, address pending) = _tarConfig(c.tar, c.token);
        if (admin == address(0)) {
            console.log(
                "[snapshot] WARN tokenAdminRegistry: administrator is 0x0 - token not registered in this TAR? "
                "If the project registers in a NON-directory TAR, re-run with TAR=<addr>."
            );
        }
        string memory obj = string.concat("roles-tar-", c.name);
        VM.serializeAddress(obj, "registry", c.tar);
        VM.serializeAddress(obj, "administrator", admin);
        return VM.serializeAddress(obj, "pendingAdministrator", pending);
    }

    // ---------------------------------------------------------------- pool

    function _poolBlock(Ctx memory c) private returns (string memory) {
        string memory obj = string.concat("roles-pool-", c.name);
        VM.serializeAddress(obj, "address", c.pool);
        VM.serializeAddress(obj, "rateLimitAdmin", c.rateLimitAdmin);
        if (c.isV2) {
            VM.serializeAddress(obj, "feeAdmin", c.feeAdmin);
            (, address hooks) = RolesProbes.tryAddress(c.pool, "getAdvancedPoolHooks()");
            VM.serializeAddress(obj, "hooks", hooks);
        }
        // NOTE: a 1.5.0 pool's pendingOwner has NO getter (ConfirmedOwner) — the owner read below is
        // the only ownership fact snapshottable across all cataloged versions.
        return VM.serializeAddress(obj, "owner", c.poolOwner);
    }

    // ---------------------------------------------------------------- lockbox / hooks

    function _lockboxBlock(string memory name, address pool) private returns (string memory) {
        (bool has, address lockbox) = RolesProbes.tryAddress(pool, "getLockBox()");
        if (!has || lockbox == address(0)) return "";
        (, address owner_) = RolesProbes.tryAddress(lockbox, "owner()");
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(lockbox, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        string memory obj = string.concat("roles-lockbox-", name);
        VM.serializeAddress(obj, "address", lockbox);
        VM.serializeAddress(obj, "owner", owner_);
        return VM.serializeAddress(obj, "authorizedCallers", callers);
    }

    /// @dev Hooks resolution: the pool's live `getAdvancedPoolHooks()` (v2, when attached) > the
    /// previously declared `.roles.hooks.address` (a deployed-but-detached hooks contract).
    function _hooksBlock(string memory name, string memory json, address pool, bool isV2)
        private
        returns (string memory)
    {
        address hooks = address(0);
        if (isV2) (, hooks) = RolesProbes.tryAddress(pool, "getAdvancedPoolHooks()");
        if (hooks == address(0) && VM.keyExistsJson(json, ".roles.hooks.address")) {
            hooks = VM.parseJsonAddress(json, ".roles.hooks.address");
        }
        if (hooks == address(0)) return "";
        (, address owner_) = RolesProbes.tryAddress(hooks, "owner()");
        (, bool allowlistEnabled) = RolesProbes.tryBool(hooks, "getAllowListEnabled()");
        (, address[] memory allowlist) = RolesProbes.tryAddressArray(hooks, abi.encodeWithSignature("getAllowList()"));
        (, address[] memory callers) =
            RolesProbes.tryAddressArray(hooks, abi.encodeWithSignature("getAllAuthorizedCallers()"));
        (, address policyEngine) = RolesProbes.tryAddress(hooks, "getPolicyEngine()");
        string memory obj = string.concat("roles-hooks-", name);
        VM.serializeAddress(obj, "address", hooks);
        VM.serializeAddress(obj, "owner", owner_);
        VM.serializeBool(obj, "allowlistEnabled", allowlistEnabled);
        VM.serializeAddress(obj, "allowlist", allowlist);
        VM.serializeAddress(obj, "policyEngine", policyEngine);
        return VM.serializeAddress(obj, "authorizedCallers", callers);
    }

    // ---------------------------------------------------------------- governance (OPTIONAL, three shapes)

    /// @dev `governance{}` is mode-aware and OPTIONAL — three valid shapes: `safe` only, `timelock`
    /// only, or both; an EOA-only chain gets NO block at all (omitted, never empty placeholders).
    /// Inference: a declared sub-block wins; otherwise the pool owner is probed — a Safe-shaped owner
    /// (getThreshold+getOwners) yields a `safe` sub-block, a timelock-shaped owner (getMinDelay) a
    /// `timelock` sub-block. Chain-readable wiring (threshold/owners/minDelay) is refreshed live;
    /// pure declarations (proposers/cancellers/executors/adminRenounced) are preserved verbatim
    /// (TimelockController roles are NOT enumerable on-chain).
    function _governanceBlock(string memory name, string memory json, address poolOwner)
        private
        returns (string memory)
    {
        address safe = address(0);
        if (VM.keyExistsJson(json, ".roles.governance.safe.address")) {
            safe = VM.parseJsonAddress(json, ".roles.governance.safe.address");
        } else if (RolesProbes.looksLikeSafe(poolOwner)) {
            safe = poolOwner;
            console.log("[snapshot] governance.safe inferred from the pool owner (Safe-shaped contract)");
        }
        address timelock = address(0);
        if (VM.keyExistsJson(json, ".roles.governance.timelock.address")) {
            timelock = VM.parseJsonAddress(json, ".roles.governance.timelock.address");
        } else if (RolesProbes.looksLikeTimelock(poolOwner)) {
            timelock = poolOwner;
            console.log("[snapshot] governance.timelock inferred from the pool owner (timelock-shaped contract)");
        }
        if (safe == address(0) && timelock == address(0)) return "";

        string memory obj = string.concat("roles-gov-", name);
        string memory out = "";
        if (safe != address(0)) {
            string memory sObj = string.concat("roles-gov-safe-", name);
            VM.serializeAddress(sObj, "address", safe);
            (, uint256 threshold) = RolesProbes.tryUint(safe, "getThreshold()");
            VM.serializeUint(sObj, "threshold", threshold);
            (, address[] memory owners) = RolesProbes.tryAddressArray(safe, abi.encodeWithSignature("getOwners()"));
            out = VM.serializeString(obj, "safe", VM.serializeAddress(sObj, "owners", owners));
        }
        if (timelock != address(0)) {
            string memory tObj = string.concat("roles-gov-tl-", name);
            VM.serializeAddress(tObj, "address", timelock);
            (, uint256 minDelay) = RolesProbes.tryUint(timelock, "getMinDelay()");
            string memory tl = VM.serializeUint(tObj, "minDelay", minDelay);
            tl = _copyDeclaredList(json, ".roles.governance.timelock.proposers", tObj, "proposers", tl);
            tl = _copyDeclaredList(json, ".roles.governance.timelock.cancellers", tObj, "cancellers", tl);
            tl = _copyDeclaredList(json, ".roles.governance.timelock.executors", tObj, "executors", tl);
            if (VM.keyExistsJson(json, ".roles.governance.timelock.adminRenounced")) {
                tl = VM.serializeBool(
                    tObj, "adminRenounced", VM.parseJsonBool(json, ".roles.governance.timelock.adminRenounced")
                );
            }
            out = VM.serializeString(obj, "timelock", tl);
        }
        return out;
    }

    function _copyDeclaredList(
        string memory json,
        string memory path,
        string memory obj,
        string memory key,
        string memory fallbackJson
    ) private returns (string memory) {
        if (!VM.keyExistsJson(json, path)) return fallbackJson;
        return VM.serializeAddress(obj, key, VM.parseJsonAddressArray(json, path));
    }
}
