// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {ChainConfig} from "../../src/config/ChainConfig.sol";
import {CcipApiSource} from "../../src/config/CcipApiSource.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {PoolVersions} from "../../src/PoolVersions.sol";
import {PoolVersion, IRateLimitGetterV2} from "../utils/PoolVersion.s.sol";
import {ITokenPoolV1RateLimiter} from "../utils/RateLimiterUtils.s.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IPoolV2} from "@chainlink/contracts-ccip/contracts/interfaces/IPoolV2.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RolesAuditor} from "../../src/roles/RolesAuditor.sol";
import {FinalityConfigUtils} from "../utils/FinalityConfigUtils.s.sol";

/// @dev The chain-membership read surface shared by every cataloged TokenPool version: both
/// `isSupportedChain(uint64)` and `getSupportedChains()` exist unchanged from 1.5.0 through 2.0.0
/// (verified against the tagged pool sources; the live 1.5.0-2.0.0 pool matrix answers both).
interface ITokenPoolChainReader {
    function isSupportedChain(uint64 remoteChainSelector) external view returns (bool);
    function getSupportedChains() external view returns (uint64[] memory);
}

/// @dev The 2.0.0 per-lane fee-config getter (`TokenPool.getTokenTransferFeeConfig`); the
/// implementation keys only on `destChainSelector` (the other parameters are accepted and ignored).
interface IPoolFeeConfigReader {
    function getTokenTransferFeeConfig(
        address localToken,
        uint64 destChainSelector,
        bytes4 requestedFinalityConfig,
        bytes calldata tokenArgs
    ) external view returns (IPoolV2.TokenTransferFeeConfig memory feeConfig);
}

/// @dev The 2.0.0 hooks pointer on the pool (`TokenPool.getAdvancedPoolHooks`); the return is an
/// `IAdvancedPoolHooks`, ABI-decoded as a plain address so no hooks interface is needed here.
interface IPoolHooksReader {
    function getAdvancedPoolHooks() external view returns (address hooks);
}

/// @dev The 2.0.0 allowed-finality getter on the pool (`TokenPool.getAllowedFinalityConfig`): the
/// bytes4 FinalityCodec value naming which fast-finality modes the pool accepts.
interface IPoolFinalityReader {
    function getAllowedFinalityConfig() external view returns (bytes4);
}

/// @dev The CCV read surface on the pool's `AdvancedPoolHooks` (2.0.0): the per-lane verifier arrays
/// (`getCCVConfig`) and the pool-global additional-CCV threshold (`getThresholdAmount`).
interface IHooksCCVReader {
    function getCCVConfig(uint64 remoteChainSelector) external view returns (AdvancedPoolHooks.CCVConfig memory);
    function getThresholdAmount() external view returns (uint256);
}

/// @dev The `typeAndVersion()` string surface. Used to confirm a hand-maintained plane's FeeQuoter
/// is the intended CCIP version: the FeeQuoter/OnRamp/OffRamp carry the discriminating version
/// string, whereas the Router reports the same string across versions, so it is never the version probe.
interface ITypeAndVersionReader {
    function typeAndVersion() external view returns (string memory);
}

/// @dev External try/catch targets for `VerifyChain` (forge forbids `this.` self-calls in ephemeral
/// script contracts). Deployed by the script, so it inherits cheatcode access; reverts from the real
/// `ChainConfig` parse paths / fork cheatcodes become catchable, attributed FAILs.
contract ChainProbe {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function parseChain(string memory name) external view returns (ChainConfig.Chain memory) {
        return ChainConfig._load(name);
    }

    function parseQuotedDecimals(string memory json) external pure returns (string memory, string memory) {
        return (VM.parseJsonString(json, ".chainId"), VM.parseJsonString(json, ".chainSelector"));
    }

    function fetchFlat(uint64 selector) external returns (string memory) {
        return (new CcipApiSource()).fetchActiveCcipConfig(selector);
    }

    function forkTo(string memory rpcUrl) external returns (uint256) {
        VM.createSelectFork(rpcUrl);
        return block.chainid;
    }

    /// @dev The pool CCIP actually routes through for `token`, read from the on-chain
    /// TokenAdminRegistry. External so a revert (no TAR entry / RPC hiccup) is catchable by VerifyChain.
    function wiredPool(address tokenAdminRegistry, address token) external view returns (address) {
        return TokenAdminRegistry(tokenAdminRegistry).getPool(token);
    }

    /// @dev Plain file read, external so the mesh rung can tolerate a config file being removed
    /// between the directory scan and the read (catchable, skipped) instead of aborting the doctor.
    function readFileFor(string memory path) external view returns (string memory) {
        return VM.readFile(path);
    }

    /// @dev `keyExistsJson`, external so the mesh rung can tolerate an unparseable snapshot (a config
    /// file mid-write by a concurrently-running test) as catchable, skipped - never an aborted run.
    function hasKey(string memory json, string memory path) external view returns (bool) {
        return VM.keyExistsJson(json, path);
    }

    /// @dev String read at a JSON path, external so a structurally-wrong node (an array/object where a
    /// scalar is expected) degrades to a catchable, named FAIL in the verifier{} rung instead of
    /// aborting the whole doctor with a raw cheatcode revert.
    function parseString(string memory json, string memory path) external pure returns (string memory) {
        return VM.parseJsonString(json, path);
    }

    /// @dev `isSupportedChain` on the pool, external so a weird pool (proxy with no fallback, wrong
    /// ABI, RPC hiccup) degrades to a catchable WARN in the lanes rung, never an aborted doctor run.
    function poolSupportsChain(address pool, uint64 selector) external view returns (bool) {
        return ITokenPoolChainReader(pool).isSupportedChain(selector);
    }

    /// @dev `getSupportedChains` on the pool, external so a pool that does not answer it degrades
    /// the reverse (on-chain -> declared) half of the lanes rung to a catchable SKIP.
    function poolSupportedChains(address pool) external view returns (uint64[] memory) {
        return ITokenPoolChainReader(pool).getSupportedChains();
    }

    /// @dev The live rate-limit bucket for one lane and one direction, dispatched on the resolved
    /// pool contract version: the v2 getter `getCurrentRateLimiterState(selector, fastFinality)`
    /// from 2.0.0, the per-direction v1 getters before (`fastFinality` is only ever true on a v2
    /// dispatch - the caller gates the fast-finality read on version 2.0.0). `UNKNOWN` degrades to
    /// best effort per the reads-degrade doctrine: v2 getter first, v1 as fallback. External so a
    /// pool answering neither getter is a catchable per-lane WARN in the lanes rung.
    function poolBucket(address pool, PoolVersions.Version version, uint64 selector, bool inbound, bool fastFinality)
        external
        view
        returns (RateLimiter.TokenBucket memory bucket)
    {
        if (version >= PoolVersions.Version.V2_0_0) {
            return _v2Bucket(pool, selector, inbound, fastFinality);
        }
        if (version != PoolVersions.Version.UNKNOWN) {
            return _v1Bucket(pool, selector, inbound);
        }
        try IRateLimitGetterV2(pool).getCurrentRateLimiterState(selector, fastFinality) returns (
            RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i
        ) {
            return inbound ? i : o;
        } catch {
            return _v1Bucket(pool, selector, inbound);
        }
    }

    function _v2Bucket(address pool, uint64 selector, bool inbound, bool fastFinality)
        private
        view
        returns (RateLimiter.TokenBucket memory)
    {
        (RateLimiter.TokenBucket memory o, RateLimiter.TokenBucket memory i) =
            IRateLimitGetterV2(pool).getCurrentRateLimiterState(selector, fastFinality);
        return inbound ? i : o;
    }

    function _v1Bucket(address pool, uint64 selector, bool inbound)
        private
        view
        returns (RateLimiter.TokenBucket memory)
    {
        return inbound
            ? ITokenPoolV1RateLimiter(pool).getCurrentInboundRateLimiterState(selector)
            : ITokenPoolV1RateLimiter(pool).getCurrentOutboundRateLimiterState(selector);
    }

    /// @dev The 2.0.0 per-lane fee config; only called after the version resolved to 2.0.0. The
    /// getter ignores every parameter except the selector. External so a pool that does not answer
    /// it is a catchable WARN in the lanes rung.
    function poolFeeConfig(address pool, uint64 selector)
        external
        view
        returns (IPoolV2.TokenTransferFeeConfig memory)
    {
        return IPoolFeeConfigReader(pool).getTokenTransferFeeConfig(address(0), selector, bytes4(0), "");
    }

    /// @dev The pool's AdvancedPoolHooks pointer (2.0.0 only; may be `address(0)` when unwired).
    /// External so a pool that does not answer it (wrong ABI, RPC hiccup) is a catchable WARN in the
    /// lanes rung, never an aborted doctor run.
    function poolHooks(address pool) external view returns (address) {
        return IPoolHooksReader(pool).getAdvancedPoolHooks();
    }

    /// @dev The live per-lane CCV config on the hooks contract. External so a hooks contract that does
    /// not answer `getCCVConfig` degrades to a catchable WARN.
    function hooksCCVConfig(address hooks, uint64 selector) external view returns (AdvancedPoolHooks.CCVConfig memory) {
        return IHooksCCVReader(hooks).getCCVConfig(selector);
    }

    /// @dev The live pool-global additional-CCV threshold on the hooks contract. External so a hooks
    /// contract that does not answer `getThresholdAmount` degrades to a catchable WARN.
    function hooksThreshold(address hooks) external view returns (uint256) {
        return IHooksCCVReader(hooks).getThresholdAmount();
    }

    /// @dev The live allowed-finality config on the pool (2.0.0). External so a pool that does not
    /// answer `getAllowedFinalityConfig` degrades to a catchable WARN, never an aborted doctor run.
    function poolAllowedFinality(address pool) external view returns (bytes4) {
        return IPoolFinalityReader(pool).getAllowedFinalityConfig();
    }

    /// @dev Encodes the declared `poolPolicy.finality` block. External so a malformed declaration
    /// (an over-range blockDepth, a non-numeric value) degrades to a catchable, named FAIL instead
    /// of aborting the doctor run.
    function parseDeclaredFinality(string memory json) external view returns (bytes4) {
        return FinalityConfigUtils._parseDeclared(json, ".poolPolicy.finality");
    }

    /// @dev The FeeQuoter's `typeAndVersion` string, external so a wrong address / RPC hiccup degrades
    /// to a catchable WARN. Probes the FeeQuoter (a version discriminator), never the Router.
    function feeQuoterTypeAndVersion(address feeQuoter) external view returns (string memory) {
        return ITypeAndVersionReader(feeQuoter).typeAndVersion();
    }
}

/// @title VerifyChain
/// @notice The layered chain-config doctor. One aligned [PASS]/[FAIL]/[WARN]/[SKIP] line per check,
/// reverting at the end iff any FAIL, so a chain can be verified end-to-end between "config file
/// edited" and "scripts run against it". Layers:
///   1. TOOLS     curl + jq present (the ffi fetch preflight)
///   2. SCHEMA    every key the real `ChainConfig._load` path consumes, incl. the quoted-decimal
///                big-int rule, plus an actual `ChainConfig._load` parse, the optional
///                `verifier{type,url}` block, and a FAIL on the removed `confirmations` key
///   3. API       re-fetch via the config-sync seam: selector<->chainId identity + field drift
///                (WARN + skip when the API is unreachable - flake is not failure)
///   4. RPC       rpcEnv set (SKIP cleanly when unset) -> fork -> block.chainid == chainId
///   5. ON-CHAIN  code present for router/rmnProxy/tokenAdminRegistry/registryModuleOwnerCustom/link
///                on the fork (proves the addresses belong on this chain)
///   6. REGISTRY  `project/<selectorName>.json` addresses.active token/tokenPool (WARN while undeployed)
///                and review-me extras (explorerUrl/nativeCurrencySymbol) - WARNs, not FAILs
///   7. MESH      every declared lane's remote config file exists and its stored `remoteSelector`
///                matches the remote's `chainSelector`, plus reciprocity across the whole mesh: a
///                one-sided lane (A declares B without B declaring A, in either direction) is a
///                FAIL naming both chains - the lane policy is committed, so the mesh must agree
///   8. LANES     declared lanes{} + poolPolicy{} reconciled against the ON-CHAIN pool, both
///                directions (RPC-gated, SKIP when the rpcEnv is unset; SKIP when no pool is
///                recorded): forward, every declared lane must be applied on the pool
///                (`isSupportedChain`) with live values matching every declared policy field
///                (version-dispatched getters); reverse, every on-chain supported selector must be
///                declared in lanes{}. A declared value the chain contradicts is a FAIL naming the
///                exact field - an emergency throttle is recorded by updating the declaration (the
///                git diff is the audit trail). Forward-intent states (declared-but-not-applied),
///                undeclared on-chain lanes, uncataloged pool versions, and unanswered reads stay
///                WARN: they are pending work or degraded visibility, not proven drift
///
/// Run: FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig "run(string)" <name>
/// @dev Non-EVM chains (e.g. solana-devnet) get the schema parse only; API/RPC/on-chain/registry
/// rungs are skipped (destination-only support, zeroed `ccip{}` by design).
contract VerifyChain is Script {
    uint256 private s_fails;
    uint256 private s_warns;
    bool private s_forked;
    ChainProbe private s_probe;

    function _pass(string memory msg_) private pure {
        console.log(string.concat("[PASS] ", msg_));
    }

    function _fail(string memory msg_) private {
        s_fails++;
        console.log(string.concat("[FAIL] ", msg_));
    }

    function _warn(string memory msg_) private {
        s_warns++;
        console.log(string.concat("[WARN] ", msg_));
    }

    function _skip(string memory msg_) private pure {
        console.log(string.concat("[SKIP] ", msg_));
    }

    function _path(string memory name) private pure returns (string memory) {
        return string.concat("config/chains/", name, ".json");
    }

    /// @dev A valid POSIX shell env-var name: [A-Za-z_][A-Za-z0-9_]* (letters, digits, underscore, no
    /// leading digit). An rpcEnv that fails this cannot be `export`ed, so the RPC-gated rungs go blind.
    function _isValidEnvName(string memory name) private pure returns (bool) {
        bytes memory b = bytes(name);
        if (b.length == 0) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            bool alpha = (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || ch == "_";
            bool digit = ch >= "0" && ch <= "9";
            if (i == 0 ? !alpha : !(alpha || digit)) return false;
        }
        return true;
    }

    /// @dev Reads `project/<name>.json` (lanes/roles/addresses), or the empty JSON object `"{}"` when the
    /// chain has no project file yet. TOCTOU-safe via the probe so a scratch file removed by a parallel
    /// test never aborts the doctor. The empty-object sentinel (NOT `""`) is deliberate: an absent
    /// project store is a NORMAL state, and `vm.keyExistsJson("", …)` REVERTS ("EOF while parsing")
    /// whereas `vm.keyExistsJson("{}", …)` correctly returns false - so every downstream lanes/roles key
    /// probe reads an absent store as "no lanes/roles" without a raw parse revert.
    function _readProject(string memory name) private view returns (string memory) {
        string memory p = ProjectStore._path(name);
        if (!vm.exists(p)) return "{}";
        try s_probe.readFileFor(p) returns (string memory data) {
            return bytes(data).length == 0 ? "{}" : data;
        } catch {
            return "{}";
        }
    }

    /// @dev Project state lives in `project/<name>.json`. A config file still carrying a `lanes{}` or
    /// `roles{}` block is not a valid config - FAIL with the exact fix, never a cryptic downstream error.
    function _checkNoStrayProjectState(string memory name, string memory json) private {
        if (vm.keyExistsJson(json, ".lanes")) {
            _fail(
                string.concat(
                    "schema: config/chains/",
                    name,
                    ".json still has a lanes{} block - it belongs in ",
                    ProjectStore._display(name),
                    ". Delete .lanes here and re-declare with make add-lane"
                )
            );
        }
        if (vm.keyExistsJson(json, ".roles")) {
            _fail(
                string.concat(
                    "schema: config/chains/",
                    name,
                    ".json still has a roles{} block - it belongs in ",
                    ProjectStore._display(name),
                    ". Delete .roles here and re-declare with make snapshot-chain"
                )
            );
        }
        if (vm.keyExistsJson(json, ".ccvThreshold")) {
            _fail(
                string.concat(
                    "schema: config/chains/",
                    name,
                    ".json has a ccvThreshold key - pool-scoped policy belongs in ",
                    ProjectStore._display(name),
                    " under poolPolicy.ccvThreshold. Delete it here and re-declare with a reviewed hand edit"
                )
            );
        }
    }

    function run(string memory name) public {
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256(bytes("sync")),
            "run with FOUNDRY_PROFILE=sync (enables ffi): FOUNDRY_PROFILE=sync forge script script/config/VerifyChain.s.sol --tc VerifyChain --sig \"run(string)\" <name>"
        );
        console.log(string.concat("== check-chain ", name, " =="));
        string memory grp = ProjectStore._group();
        if (bytes(grp).length != 0) {
            console.log(string.concat("== token group ", grp, " =="));
        } else if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            _noticeGroupedSiblings(name);
        }
        s_probe = new ChainProbe();

        _checkTools();

        string memory path = _path(name);
        if (!vm.exists(path)) {
            _fail(
                string.concat(
                    "config: no ",
                    path,
                    " - new chain? FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"init(string,uint256)\" ",
                    name,
                    " <chainSelector>"
                )
            );
            _verdict(name);
            return;
        }
        string memory json = vm.readFile(path);
        string memory projectJson = _readProject(name);
        bool isEvm = _checkSchema(name, json);
        _checkNoStrayProjectState(name, json); // lanes{}/roles{} must not linger in the config file
        if (isEvm) {
            _checkApi(name, json);
            bool rpcOk = _checkRpc(json);
            if (rpcOk) _checkOnChainCode(name, json);
            _checkRegistryAndExtras(name, json);
            _checkMesh(name, json, projectJson);
            _checkLanesOnChain(name, json, projectJson);
            _checkRoles(name, projectJson, rpcOk);
        } else {
            // Non-EVM chains have no EVM-shaped ccip{} to sync, so the API/RPC/on-chain/registry
            // rungs are skipped - but the selectorName IS validatable for every family (chainId is a
            // placeholder "0" here, so it is the only identity the doctor can check).
            _checkSelectorNameNonEvm(json);
            _skip("rpc/on-chain/registry: non-EVM chain (destination-only support) - schema + selectorName only");
        }
        _verdict(name);
    }

    function _verdict(string memory name) private view {
        console.log(
            string.concat(
                "== check-chain ", name, ": ", vm.toString(s_fails), " FAIL, ", vm.toString(s_warns), " WARN =="
            )
        );
        require(s_fails == 0, string.concat("check-chain FAILED for ", name, " - see [FAIL] lines above"));
    }

    // ---------------------------------------------------------------- 1. TOOLS
    function _checkTools() private {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-lc";
        cmd[2] = "command -v curl >/dev/null && command -v jq >/dev/null";
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode == 0) _pass("tools: curl + jq present");
        else _fail("tools: curl and/or jq missing - install them (brew install curl jq)");
    }

    // ---------------------------------------------------------------- 2. SCHEMA
    function _checkSchema(string memory name, string memory json) private returns (bool isEvm) {
        if (!vm.keyExistsJson(json, ".chainFamily")) {
            _fail("schema: missing .chainFamily");
            return false;
        }
        isEvm = keccak256(bytes(vm.parseJsonString(json, ".chainFamily"))) == keccak256(bytes("evm"));

        // quoted-decimal big-int rule (bare JSON numbers lose precision above 2^53)
        try s_probe.parseQuotedDecimals(json) {
            _pass("schema: chainId + chainSelector are quoted decimal strings");
        } catch {
            _fail("schema: chainId/chainSelector must be quoted decimal STRINGS (see config/chains/*.json)");
        }

        string[16] memory required = [
            ".name",
            ".displayName",
            ".chainNameIdentifier",
            ".chainId",
            ".chainSelector",
            ".rpcEnv",
            ".explorerUrl",
            ".nativeCurrencySymbol",
            ".ccip.router",
            ".ccip.rmnProxy",
            ".ccip.tokenAdminRegistry",
            ".ccip.registryModuleOwnerCustom",
            ".ccip.link",
            ".ccip.feeQuoter",
            ".ccip.tokenPoolFactory",
            ".ccip.feeTokens"
        ];
        uint256 missing = 0;
        for (uint256 i = 0; i < required.length; i++) {
            if (!vm.keyExistsJson(json, required[i])) {
                _fail(string.concat("schema: missing key ", required[i]));
                missing++;
            }
        }
        if (missing == 0) _pass("schema: all keys consumed by ChainConfig._load + the sync tooling present");

        // configSource is an OPTIONAL key (absent = "api", the API-synced default). When present it
        // must name a known plane so a typo can never silently disable the API drift check below.
        if (vm.keyExistsJson(json, ".configSource")) {
            string memory cs = vm.parseJsonString(json, ".configSource");
            if (keccak256(bytes(cs)) == keccak256(bytes("api")) || keccak256(bytes(cs)) == keccak256(bytes("manual"))) {
                _pass(string.concat("schema: configSource '", cs, "' is a known address plane"));
            } else {
                _fail(string.concat("schema: configSource '", cs, "' is not a known plane - use \"api\" or \"manual\""));
            }
        }

        try s_probe.parseChain(name) {
            _pass("schema: ChainConfig._load parses (the real read path)");
        } catch Error(string memory reason) {
            _fail(string.concat("schema: ChainConfig._load reverts - ", reason));
        } catch {
            _fail("schema: ChainConfig._load reverts (cheatcode parse error - check value formats)");
        }

        if (vm.keyExistsJson(json, ".confirmations")) {
            _fail(
                string.concat(
                    "schema: config/chains/",
                    name,
                    ".json still has a confirmations key - the field was removed (nothing consumes it; explorer",
                    " verification uses verify-side retries instead). Delete .confirmations"
                )
            );
        }
        _checkVerifierBlock(name, json);
    }

    /// @dev The optional hand-authored `verifier{type,url}` block: `type` must be one of
    /// `etherscan` / `blockscout` / `sourcify`, and `blockscout` requires a `url` (its API endpoint
    /// cannot be derived). A config with NO block is valid: bare `--verify` resolves Etherscan v2
    /// from the chain id and forge falls back to Sourcify for chains Etherscan does not serve.
    /// Every value read goes through the probe so a structurally-wrong node (`type`/`url` written as a
    /// JSON array or object) is a NAMED FAIL, never a raw cheatcode revert that aborts the doctor; and
    /// the blockscout `url` must be an `http(s)` endpoint so a bare number/bool cannot slip through as
    /// a valid url (`vm.parseJsonString` would otherwise coerce `123` to `"123"`).
    function _checkVerifierBlock(string memory name, string memory json) private {
        if (!vm.keyExistsJson(json, ".verifier")) return;
        (bool typeOk, string memory vtype) = _verifierString(json, ".verifier.type");
        if (!typeOk) {
            _fail(
                string.concat(
                    "schema: verifier{} in config/chains/",
                    name,
                    ".json needs a string .verifier.type (etherscan/blockscout/sourcify)"
                )
            );
            return;
        }
        bytes32 t = keccak256(bytes(vtype));
        bool known = t == keccak256(bytes("etherscan")) || t == keccak256(bytes("blockscout"))
            || t == keccak256(bytes("sourcify"));
        if (!known) {
            _fail(
                string.concat(
                    "schema: verifier.type '",
                    vtype,
                    "' in config/chains/",
                    name,
                    ".json is not one of etherscan/blockscout/sourcify"
                )
            );
            return;
        }
        if (t == keccak256(bytes("blockscout"))) {
            (bool urlOk, string memory url) = _verifierString(json, ".verifier.url");
            if (!urlOk || !_hasPrefix(url, "http")) {
                _fail(
                    string.concat(
                        "schema: verifier.type blockscout in config/chains/",
                        name,
                        ".json needs an http(s) verifier.url (the instance API endpoint, usually <explorerUrl>/api)"
                    )
                );
                return;
            }
        }
        _pass(string.concat("schema: verifier{} is valid (", vtype, ")"));
    }

    /// @dev Reads a verifier{} string key through the probe: returns `(false, "")` when the key is
    /// absent OR its value is not a JSON string the parse can read (an array/object reverts, and the
    /// probe's external call makes that revert catchable). A scalar number/bool coerces to its text
    /// here, so callers that need a real string (the blockscout url) additionally shape-check it.
    function _verifierString(string memory json, string memory path)
        private
        view
        returns (bool ok, string memory value)
    {
        if (!vm.keyExistsJson(json, path)) return (false, "");
        try s_probe.parseString(json, path) returns (string memory s) {
            return (true, s);
        } catch {
            return (false, "");
        }
    }

    // ---------------------------------------------------------------- 3. API
    function _checkApi(string memory name, string memory json) private {
        // A manual-plane chain declares that a reviewed hand edit owns its ccip{} addresses, so the
        // API is not the writer to drift-check against: SKIP the drift check and WARN about the one
        // residual risk (an address change to this plane is not detectable from the API).
        if (ChainConfig._isManual(json)) {
            _skip(
                string.concat(
                    "api: configSource=manual for ",
                    name,
                    " - the API does not serve this address plane; git is the audit trail"
                )
            );
            _warn(
                "api: manual plane - an address change is not API-detectable; on a failure re-verify the ccip{} addresses against your address source"
            );
            return;
        }
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));
        string memory flat;
        try s_probe.fetchFlat(selector) returns (string memory f) {
            flat = f;
        } catch Error(string memory reason) {
            _warn(string.concat("api: fetch failed - drift check skipped: ", reason));
            return;
        } catch {
            _warn("api: fetch failed - drift check skipped");
            return;
        }
        // selector <-> chainId identity (a valid-but-wrong selector is the worst silent failure)
        uint256 localChainId = vm.parseJsonUint(json, ".chainId");
        uint256 apiChainId = vm.parseJsonUint(flat, ".chainId");
        string memory apiName = vm.parseJsonString(flat, ".apiName");
        if (localChainId == apiChainId) {
            _pass(string.concat("api: selector ", vm.toString(selector), " resolves to this chainId (", apiName, ")"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR MISMATCH - config chainId ",
                    vm.toString(localChainId),
                    " but selector is chainId ",
                    vm.toString(apiChainId),
                    " (",
                    apiName,
                    ") - fix .chainSelector"
                )
            );
            return;
        }
        // selectorName identity: the config `name` must be the canonical CCIP selectorName (the
        // universal key shared by the API and ccip-cli) for this selector.
        string memory localName = vm.parseJsonString(json, ".name");
        if (keccak256(bytes(localName)) == keccak256(bytes(apiName))) {
            _pass(string.concat("api: config name '", localName, "' matches the canonical selectorName"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR NAME MISMATCH - config name '",
                    localName,
                    "' but the selector's canonical selectorName is '",
                    apiName,
                    "' - set .name and rename the file to ",
                    apiName,
                    ".json"
                )
            );
        }
        // field drift vs the stored ccip{} block (same key list the sync writes)
        string[7] memory keys = [
            "router",
            "rmnProxy",
            "tokenAdminRegistry",
            "registryModuleOwnerCustom",
            "link",
            "feeQuoter",
            "tokenPoolFactory"
        ];
        uint256 drift = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            address cur = vm.parseJsonAddress(json, string.concat(".ccip.", keys[i]));
            address live = vm.parseJsonAddress(flat, string.concat(".", keys[i]));
            if (cur != live) {
                _fail(string.concat("api: DRIFT .ccip.", keys[i], " ", vm.toString(cur), " -> ", vm.toString(live)));
                drift++;
            }
        }
        if (drift == 0) {
            _pass("api: .ccip matches the live API (no drift)");
        } else {
            _fail(
                string.concat(
                    "api: ",
                    vm.toString(drift),
                    " field(s) drifted - refresh: FOUNDRY_PROFILE=sync forge script script/config/SyncCcipConfig.s.sol --sig \"run(string)\" ",
                    name
                )
            );
        }
    }

    /// @dev Non-EVM selectorName rung: fetch the chain-list identity row by selector and assert the
    /// config `name` equals the canonical selectorName. Uses the same meta helper the sync's
    /// add-chain path uses (works for every family). API flake is a WARN, not a FAIL.
    function _checkSelectorNameNonEvm(string memory json) private {
        uint64 selector = uint64(vm.parseJsonUint(json, ".chainSelector"));
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "script/config/ccip-chain-meta.sh";
        cmd[2] = vm.toString(uint256(selector));
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        if (r.exitCode != 0) {
            _warn("api: selectorName check skipped - chain metadata fetch failed (flake, not config error)");
            return;
        }
        string memory apiName = vm.parseJsonString(string(r.stdout), ".apiName");
        string memory localName = vm.parseJsonString(json, ".name");
        if (keccak256(bytes(localName)) == keccak256(bytes(apiName))) {
            _pass(string.concat("api: config name '", localName, "' matches the canonical selectorName"));
        } else {
            _fail(
                string.concat(
                    "api: SELECTOR NAME MISMATCH - config name '",
                    localName,
                    "' but the selector's canonical selectorName is '",
                    apiName,
                    "' - set .name and rename the file to ",
                    apiName,
                    ".json"
                )
            );
        }
    }

    // ---------------------------------------------------------------- 4. RPC
    function _checkRpc(string memory json) private returns (bool ok) {
        string memory rpcEnv = vm.parseJsonString(json, ".rpcEnv");
        // A POSIX shell env-var name must be [A-Za-z_][A-Za-z0-9_]*. If the derived rpcEnv is not (most
        // often a leading digit, e.g. "0G_..._RPC_URL"), `export`/dotenv silently rejects it, so the
        // url below reads back empty and every RPC-gated rung SKIPs - a doctor that looks green while
        // having verified nothing on-chain. Surface it as a WARN so the blind spot is visible; the fix
        // is to set a valid CHAIN_NAME_IDENTIFIER / RPC_ENV (add-chain prefixes a leading digit).
        if (!_isValidEnvName(rpcEnv)) {
            _warn(
                string.concat(
                    "rpc: rpcEnv '",
                    rpcEnv,
                    "' is not a valid shell identifier (a shell cannot export it), so RPC-dependent checks",
                    " below will SKIP - set a valid RPC_ENV in config/chains and your .env"
                )
            );
        }
        string memory url = vm.envOr(rpcEnv, string(""));
        if (bytes(url).length == 0) {
            _skip(string.concat("rpc: env ", rpcEnv, " unset - add it to your .env to enable fork checks"));
            return false;
        }
        try s_probe.forkTo(url) returns (uint256 forkChainId) {
            uint256 expected = vm.parseJsonUint(json, ".chainId");
            if (forkChainId == expected) {
                s_forked = true;
                _pass(string.concat("rpc: ", rpcEnv, " reachable, block.chainid == ", vm.toString(expected)));
                return true;
            }
            _fail(
                string.concat(
                    "rpc: ",
                    rpcEnv,
                    " points at chainId ",
                    vm.toString(forkChainId),
                    " but config says ",
                    vm.toString(expected),
                    " (wrong network in .env?)"
                )
            );
        } catch {
            _fail(string.concat("rpc: could not fork via ", rpcEnv, " - endpoint down or URL invalid"));
        }
        return false;
    }

    // ---------------------------------------------------------------- 5. ON-CHAIN
    function _checkOnChainCode(string memory name, string memory json) private {
        if (!s_forked) return;
        string[5] memory keys = ["router", "rmnProxy", "tokenAdminRegistry", "registryModuleOwnerCustom", "link"];
        uint256 bad = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            address a = vm.parseJsonAddress(json, string.concat(".ccip.", keys[i]));
            if (a.code.length == 0) {
                _fail(
                    string.concat(
                        "on-chain: .ccip.", keys[i], " ", vm.toString(a), " has NO code on ", name, " (wrong chain?)"
                    )
                );
                bad++;
            }
        }
        if (bad == 0) {
            _pass("on-chain: router/rmnProxy/tokenAdminRegistry/registryModuleOwnerCustom/link all have code");
        }
        // On a hand-maintained plane the API drift check does not run, so log the FeeQuoter's
        // typeAndVersion as a quick check that the ccip{} addresses are the intended CCIP version.
        // Guard the read so a config missing .ccip.feeQuoter degrades to a WARN, never a raw abort.
        if (ChainConfig._isManual(json)) {
            if (!vm.keyExistsJson(json, ".ccip.feeQuoter")) {
                _warn(
                    string.concat(
                        "on-chain: ", name, " is manual but has no .ccip.feeQuoter - cannot check the plane version"
                    )
                );
            } else {
                address feeQuoter = vm.parseJsonAddress(json, ".ccip.feeQuoter");
                try s_probe.feeQuoterTypeAndVersion(feeQuoter) returns (string memory tv) {
                    _pass(string.concat("on-chain: feeQuoter ", vm.toString(feeQuoter), " typeAndVersion = ", tv));
                } catch {
                    _warn(
                        string.concat(
                            "on-chain: feeQuoter ", vm.toString(feeQuoter), " did not answer typeAndVersion on ", name
                        )
                    );
                }
            }
        }
    }

    // ---------------------------------------------------------------- 6. REGISTRY + EXTRAS
    function _checkRegistryAndExtras(string memory name, string memory json) private {
        address token = RegistryWriter._read(name, "token");
        address pool = RegistryWriter._read(name, "tokenPool");
        if (token == address(0)) {
            _warn(
                string.concat(
                    "registry: no token in ",
                    ProjectStore._display(name),
                    " - deploy one (script/deploy/DeployToken.s.sol) or export {CHAIN}_TOKEN"
                )
            );
        } else if (s_forked && token.code.length == 0) {
            _fail(string.concat("registry: token ", vm.toString(token), " has NO code on ", name));
        } else {
            _pass(string.concat("registry: token ", vm.toString(token), s_forked ? " (has code)" : " (set; no fork)"));
        }
        if (pool == address(0)) {
            _warn(
                string.concat("registry: no tokenPool in ", ProjectStore._display(name), " - deploy one before Step 3+")
            );
        } else if (s_forked && pool.code.length == 0) {
            _fail(string.concat("registry: tokenPool ", vm.toString(pool), " has NO code on ", name));
        } else {
            _pass(
                string.concat("registry: tokenPool ", vm.toString(pool), s_forked ? " (has code)" : " (set; no fork)")
            );
        }
        _warnMultiPoolAmbiguity(name);

        // Reconcile the registry's pool against the ON-CHAIN TokenAdminRegistry. `active.tokenPool` is
        // "what this repo deployed most recently"; the TAR is "the pool CCIP actually routes through".
        // They legitimately diverge whenever the wired pool was changed out-of-band (the TAR was pointed
        // at a different pool outside this repo's scripts), so this is always a WARN, never a FAIL.
        if (token != address(0) && pool != address(0)) {
            // Read the TAR address INSIDE the defensive path: a config missing `.ccip.tokenAdminRegistry`
            // must degrade to a WARN, not revert the whole doctor with a raw parse error (the missing key
            // is already reported by the schema rung above). Only reconcile when the key is present.
            if (vm.keyExistsJson(json, ".ccip.tokenAdminRegistry")) {
                _reconcilePoolWithTar(vm.parseJsonAddress(json, ".ccip.tokenAdminRegistry"), token, pool);
            } else {
                _warn(
                    "registry: .ccip.tokenAdminRegistry missing - cannot reconcile the registry pool against on-chain wiring"
                );
            }
        }

        // Extras (WARN, never FAIL). explorerUrl/nativeCurrencySymbol are API-sourced by the sync, so
        // empty means the API served none for this chain - re-run `make sync` or fill by hand.
        if (bytes(vm.parseJsonString(json, ".explorerUrl")).length == 0) {
            _warn("extras: explorerUrl is empty - run `make sync` (it is sourced from chainMetadata.explorer.url)");
        }
        if (bytes(vm.parseJsonString(json, ".nativeCurrencySymbol")).length == 0) {
            _warn(
                "extras: nativeCurrencySymbol is empty - run `make sync` (sourced from chainMetadata.nativeCurrency.symbol)"
            );
        }
    }

    /// @dev WARN (never FAIL) when `deployments{}` holds more than one token pool while
    /// `active.tokenPool` can only point at one of them: on a multi-token chain the zero-export
    /// resolution serves that ONE pool for every token. Names a token group as the durable fix (each
    /// token gets its own store) and the targeted env override as the one-off.
    function _warnMultiPoolAmbiguity(string memory name) private {
        string memory p = ProjectStore._path(name);
        if (!vm.exists(p)) return;
        string memory json;
        try s_probe.readFileFor(p) returns (string memory data) {
            json = data;
        } catch {
            return;
        }
        if (!vm.keyExistsJson(json, ".addresses.deployments")) return;
        string[] memory keys = vm.parseJsonKeys(json, ".addresses.deployments");
        uint256 pools = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (_contains(keys[i], "TokenPool_")) pools++;
        }
        if (pools > 1) {
            _warn(
                string.concat(
                    "registry: deployments{} holds ",
                    vm.toString(pools),
                    " token pools but active.tokenPool points at ONE - a no-override run resolves that one for every token. Give each token its own group (the durable fix): make adopt-token CHAIN=", // durable fix
                    name,
                    " TOKEN=<addr> TOKEN_POOL=<addr> GROUP=<g>; or for a one-off, pass {CHAIN}_TOKEN_POOL to target a specific pool (see docs/deployed-addresses.md)"
                )
            );
        }
    }

    /// @dev Substring test (ASCII, short needles).
    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev Registry-pool vs on-chain-TAR reconciliation (WARN-only). Needs an RPC (skips when not
    /// forked). Defensive: a token with no TAR entry / an RPC hiccup degrades to a WARN, never an
    /// unhandled revert that would kill the whole doctor run.
    function _reconcilePoolWithTar(address tar, address token, address pool) private {
        if (!s_forked) {
            _skip(
                "registry: TAR reconciliation needs an RPC (no fork) - registry pool not checked against on-chain wiring"
            );
            return;
        }
        try s_probe.wiredPool(tar, token) returns (address wired) {
            if (wired == pool) {
                _pass(
                    string.concat(
                        "registry: tokenPool ", vm.toString(pool), " is the pool wired in the TokenAdminRegistry"
                    )
                );
            } else if (wired == address(0)) {
                _warn(
                    string.concat(
                        "registry: token ",
                        vm.toString(token),
                        " has no pool registered in the TokenAdminRegistry - run script/setup/SetPool.s.sol"
                    )
                );
            } else {
                _warn(
                    string.concat(
                        "registry: tokenPool ",
                        vm.toString(pool),
                        " is NOT the wired pool (",
                        vm.toString(wired),
                        ") - the wired pool was changed out-of-band; otherwise the registry pointer is stale"
                    )
                );
            }
        } catch {
            _warn(
                string.concat(
                    "registry: could not read the TokenAdminRegistry (",
                    vm.toString(tar),
                    ") for token ",
                    vm.toString(token),
                    " - RPC hiccup or no TAR entry; skipping the wired-pool reconciliation"
                )
            );
        }
    }

    /// @notice Test hook: runs ONLY the registry-vs-TAR reconciliation against the currently-selected
    /// fork and returns `(fails, warns)`. Lets a fork test assert the WARN-not-FAIL contract (divergence
    /// must never increment `fails`) without the full ffi/API doctor run. Not used by any production path.
    function reconcilePoolWithTarForTest(address tar, address token, address pool)
        public
        returns (uint256 failsOut, uint256 warnsOut)
    {
        s_forked = true;
        s_probe = new ChainProbe();
        _reconcilePoolWithTar(tar, token, pool);
        return (s_fails, s_warns);
    }

    // ---------------------------------------------------------------- 7. MESH
    /// @dev Lane + mesh-reciprocity rungs. Forward: every declared lane's remote config file exists
    /// and the lane's stored `remoteSelector` equals the remote's `chainSelector`; a remote that does
    /// not declare the lane back is a FAIL naming both chains. Reverse: every OTHER config declaring
    /// a lane to this chain must be declared back here (so doctoring EITHER side of a one-sided lane
    /// catches it). Non-EVM remotes are exempt from reciprocity: they are destination-only in this
    /// repo and carry no lanes{} to reciprocate with.
    function _checkMesh(string memory name, string memory json, string memory projectJson) private {
        string[] memory mine =
            vm.keyExistsJson(projectJson, ".lanes") ? vm.parseJsonKeys(projectJson, ".lanes") : new string[](0);
        if (mine.length == 0) {
            _skip(
                string.concat(
                    "mesh: no lanes declared - wire one: make add-lane LOCAL=",
                    name,
                    " REMOTE=<remote> CAPACITY=<wei> RATE=<wei> [BOTH=1]"
                )
            );
        }
        // This chain's own address plane (from the config the caller already read), so each lane can be
        // checked for a cross-plane peer.
        bool localManual = ChainConfig._isManual(json);
        uint256 failsBefore = s_fails;
        for (uint256 i = 0; i < mine.length; i++) {
            _checkOwnLane(name, projectJson, mine[i], localManual);
        }
        if (mine.length > 0 && s_fails == failsBefore) {
            _pass(
                string.concat(
                    "mesh: all ",
                    vm.toString(mine.length),
                    " lane(s) resolve to config files, selectors match, reciprocity holds"
                )
            );
        }
        _checkReverseReciprocity(name, projectJson);
    }

    /// @dev One declared lane: the remote's config file exists (chain facts), the stored remoteSelector
    /// matches the remote's chainSelector, and the remote's PROJECT store declares the lane back. Chain
    /// facts come from `config/chains/<remote>.json`; the reciprocal lane from `project/<remote>.json`.
    function _checkOwnLane(string memory name, string memory projectJson, string memory remote, bool localManual)
        private
    {
        string memory rPath = _path(remote);
        if (!vm.exists(rPath)) {
            _fail(string.concat("mesh: lanes.", remote, " has no config/chains/", remote, ".json (dangling lane)"));
            return;
        }
        string memory rcfg = vm.readFile(rPath);
        string memory lanePath = string.concat(".lanes.", remote);
        if (!vm.keyExistsJson(projectJson, string.concat(lanePath, ".remoteSelector"))) {
            _fail(string.concat("mesh: lanes.", remote, " has no remoteSelector - re-add it: make add-lane"));
            return;
        }
        string memory stored = vm.parseJsonString(projectJson, string.concat(lanePath, ".remoteSelector"));
        string memory actual = vm.parseJsonString(rcfg, ".chainSelector");
        if (keccak256(bytes(stored)) != keccak256(bytes(actual))) {
            _fail(
                string.concat(
                    "mesh: lanes.",
                    remote,
                    ".remoteSelector ",
                    stored,
                    " != ",
                    remote,
                    "'s chainSelector ",
                    actual,
                    " - remove the entry and re-add it: make add-lane"
                )
            );
            return;
        }
        // Cross-plane lane: both endpoints must share an address plane (both API-sourced or both
        // hand-maintained). Doctoring either endpoint catches it, since each checks its own lanes.
        if (localManual != ChainConfig._isManual(rcfg)) {
            _fail(
                string.concat(
                    "mesh: cross-plane lane ",
                    name,
                    " (configSource=",
                    localManual ? "manual" : "api",
                    ") -> ",
                    remote,
                    " (configSource=",
                    ChainConfig._isManual(rcfg) ? "manual" : "api",
                    ") - a lane must connect two chains on the same address plane"
                )
            );
            return;
        }
        if (keccak256(bytes(vm.parseJsonString(rcfg, ".chainFamily"))) != keccak256(bytes("evm"))) {
            _skip(string.concat("mesh: ", remote, " is non-EVM (destination-only) - reciprocity not applicable"));
            return;
        }
        string memory rproj = _readProject(remote);
        if (!vm.keyExistsJson(rproj, string.concat(".lanes.", name))) {
            _fail(
                string.concat(
                    "mesh: one-sided lane ",
                    name,
                    " -> ",
                    remote,
                    " (",
                    remote,
                    " has no lanes.",
                    name,
                    " entry) - add the reciprocal: make add-lane LOCAL=",
                    remote,
                    " REMOTE=",
                    name,
                    " CAPACITY=<wei> RATE=<wei>"
                )
            );
        }
    }

    /// @dev The reverse direction: any OTHER chain declaring a lane to this one must be declared back
    /// here. Iterates the config/chains directory (the canonical chain list), reading each chain's
    /// PROJECT store for its lanes through the probe so a file removed mid-scan (a concurrently-running
    /// test's scratch chain) is skipped, never an aborted doctor run.
    function _checkReverseReciprocity(string memory name, string memory projectJson) private {
        Vm.DirEntry[] memory entries = vm.readDir("config/chains");
        for (uint256 i = 0; i < entries.length; i++) {
            string memory other = _jsonBasename(entries[i].path);
            if (bytes(other).length == 0 || keccak256(bytes(other)) == keccak256(bytes(name))) continue;
            string memory oproj = _readProject(other);
            if (bytes(oproj).length == 0) continue; // the other chain has no project store -> no lanes
            bool declaresMe;
            try s_probe.hasKey(oproj, string.concat(".lanes.", name)) returns (bool has) {
                declaresMe = has;
            } catch {
                continue;
            }
            if (!declaresMe) continue;
            if (!vm.keyExistsJson(projectJson, string.concat(".lanes.", other))) {
                _fail(
                    string.concat(
                        "mesh: one-sided lane ",
                        other,
                        " -> ",
                        name,
                        " (",
                        name,
                        " has no lanes.",
                        other,
                        " entry) - add the reciprocal: make add-lane LOCAL=",
                        name,
                        " REMOTE=",
                        other,
                        " CAPACITY=<wei> RATE=<wei>"
                    )
                );
            }
        }
    }

    /// @dev In the default (ungrouped) run, list any token groups that also hold this chain, so a
    /// routine check does not silently skip a grouped token. Fires only when `project/<g>/<name>.json`
    /// exists in some group directory; a single-group clone (no group dirs) prints nothing, so the
    /// one-token output is unchanged.
    function _noticeGroupedSiblings(string memory name) private view {
        string memory groups = _groupedSiblings(name);
        if (bytes(groups).length != 0) {
            console.log(
                string.concat(
                    "[doctor] note: ",
                    name,
                    " also has token group(s): ",
                    groups,
                    " - check each with make doctor CHAIN=",
                    name,
                    " GROUP=<g>"
                )
            );
        }
    }

    /// @dev Comma-joined names of the token groups whose directory holds `project/<g>/<name>.json`
    /// ("" when none). Reads the `project` directory; a group dir removed mid-scan is skipped. Scratch
    /// (`zz-scratch-*`) and local (`local-*`) directories are skipped so a leaked scratch dir, invisible
    /// to `git status`, never surfaces as a bogus notice.
    function _groupedSiblings(string memory name) private view returns (string memory groups) {
        if (!vm.exists("project")) return "";
        Vm.DirEntry[] memory entries = vm.readDir("project");
        for (uint256 i = 0; i < entries.length; i++) {
            if (!entries[i].isDir) continue;
            string memory g = _lastSegment(entries[i].path);
            if (_hasPrefix(g, "zz-scratch-") || _hasPrefix(g, "local-")) continue;
            if (!vm.exists(string.concat(entries[i].path, "/", name, ".json"))) continue;
            groups = bytes(groups).length == 0 ? g : string.concat(groups, ", ", g);
        }
    }

    /// @dev True when `s` starts with `prefix`.
    function _hasPrefix(string memory s, string memory prefix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        if (p.length > b.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }

    /// @notice Test hook: the grouped-sibling list the ungrouped doctor notices for `name` (see
    /// `_noticeGroupedSiblings`). Lets a test assert group detection without a full doctor run.
    function groupedSiblingsForTest(string memory name) public view returns (string memory) {
        return _groupedSiblings(name);
    }

    /// @dev The last "/"-separated segment of a path ("/a/b/usdx" -> "usdx").
    function _lastSegment(string memory p) private pure returns (string memory) {
        bytes memory b = bytes(p);
        uint256 start = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "/") start = i + 1;
        }
        bytes memory out = new bytes(b.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /// @dev "config/chains/ethereum-testnet-sepolia.json" -> "ethereum-testnet-sepolia" (empty for
    /// non-.json entries). Mirrors `SyncCcipConfig._jsonBasename`.
    function _jsonBasename(string memory filePath) private pure returns (string memory) {
        bytes memory b = bytes(filePath);
        bytes memory suffix = bytes(".json");
        if (b.length < suffix.length) return "";
        for (uint256 i = 0; i < suffix.length; i++) {
            if (b[b.length - suffix.length + i] != suffix[i]) return "";
        }
        uint256 start = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "/") start = i + 1;
        }
        bytes memory out = new bytes(b.length - suffix.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    /// @notice Test hook: runs ONLY the mesh rung (lane resolution + reciprocity) for `name` and
    /// returns `(fails, warns)`. Lets a Foundry test assert the reciprocity contract (a one-sided
    /// lane must increment `fails`) without the ffi/API doctor rungs. Not used by any production path.
    function checkMeshForTest(string memory name) public returns (uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        _checkMesh(name, s_probe.readFileFor(_path(name)), _readProject(name));
        return (s_fails, s_warns);
    }

    /// @notice Test hook for the schema rung's stray-project-state diagnostic
    /// (`_checkNoStrayProjectState`): a `config/chains/<name>.json` still carrying a `lanes{}`/`roles{}`
    /// block is a NAMED FAIL pointing at `project/<name>.json`; a pure
    /// API/chain-facts config neither FAILs nor WARNs. Reads the CONFIG file (chain facts), not the
    /// project store. Returns (fails, warns).
    function checkNoStrayProjectStateForTest(string memory name) public returns (uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        _checkNoStrayProjectState(name, vm.readFile(string.concat("config/chains/", name, ".json")));
        return (s_fails, s_warns);
    }

    /// @notice Test hook: runs ONLY the SCHEMA rung (`_checkSchema`) against `name`'s config and returns
    /// `(isEvm, fails, warns)`. Lets a UNIT test (no fork, no ffi/API) assert the clean-chain PASS
    /// (every key `ChainConfig._load` consumes is present → 0 FAIL) and the induced-FAIL-naming-the-field
    /// contract (a missing key FAILs, naming it) without the network rungs. Not used by any production
    /// path. Reads the CONFIG file (chain facts).
    function checkSchemaForTest(string memory name) public returns (bool isEvm, uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        isEvm = _checkSchema(name, vm.readFile(string.concat("config/chains/", name, ".json")));
        return (isEvm, s_fails, s_warns);
    }

    /// @notice Test hook: runs ONLY the API rung (`_checkApi`) against `name`'s config, returning
    /// `(fails, warns)`. For a manual-plane chain (`configSource: "manual"`) the rung returns before
    /// any API fetch, so a UNIT test (no fork, no ffi/API) can assert the SKIP + WARN branch. Reads the
    /// CONFIG file (chain facts). Not used by any production path.
    function checkApiForTest(string memory name) public returns (uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        _checkApi(name, vm.readFile(string.concat("config/chains/", name, ".json")));
        return (s_fails, s_warns);
    }

    /// @notice Test hook: runs ONLY the roles anchor-drift check (`_warnAnchorDrift` for the `token` and
    /// `pool` anchors) for `name` against its project store, returning `(fails, warns)`. Lets a UNIT test
    /// (no RPC, no auditor) assert the WARN-not-FAIL contract: a declared `roles.<x>.address` anchor that
    /// diverges from `addresses.active.<role>` emits exactly one WARN naming both + `make snapshot-chain`,
    /// while a matching anchor, an absent anchor, or a store with no active pointer stays silent. Not used
    /// by any production path - the production caller is `_checkRoles` (behind the roles-block + RPC gates).
    function warnAnchorDriftForTest(string memory name) public returns (uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        string memory projectJson = _readProject(name);
        _warnAnchorDrift(name, projectJson, ".roles.token.address", "token", "roles.token.address");
        _warnAnchorDrift(name, projectJson, ".roles.pool.address", "tokenPool", "roles.pool.address");
        return (s_fails, s_warns);
    }

    /// @notice TEST-ONLY hook: runs the multi-pool ambiguity check for `name` against its project
    /// store, returning `(fails, warns)`. Lets a UNIT test assert the WARN-not-FAIL contract: two or
    /// more `deployments{}` token pools emit exactly one WARN; zero or one pool stays silent. Not used
    /// by any production path - the production caller is `_checkRegistryAndExtras`.
    function warnMultiPoolAmbiguityForTest(string memory name) public returns (uint256 failsOut, uint256 warnsOut) {
        s_probe = new ChainProbe();
        _warnMultiPoolAmbiguity(name);
        return (s_fails, s_warns);
    }

    // ---------------------------------------------------------------- 8. LANES (on-chain)
    /// @dev On-chain lane reconciliation. The mesh rung (7) proves the committed lane policy agrees
    /// with ITSELF across the config directory; this rung proves it agrees with the CHAIN. RPC-gated
    /// like the TAR rung (SKIP with no fork), pool-gated like the registry rung (SKIP when no pool is
    /// recorded). A declared value the live chain contradicts is a FAIL naming the exact field; a
    /// declared-but-not-applied lane, an on-chain lane added out-of-band, and any unanswered read
    /// stay WARN (pending work or degraded visibility, never proven drift).
    /// @dev The ROLES rung: mounts the read-only `RolesAuditor`. It reconciles the declared
    /// `roles{}` authority surface against the live chain, folding the auditor's [PASS]/[FAIL]/[WARN]/
    /// [SKIP] tallies into the doctor's own. A chain with no `roles{}` block SKIPs (bootstrap it with
    /// `make snapshot-chain`); a chain with no RPC SKIPs (the reconcile is all live point-reads).
    /// `make roles-check` runs the same auditor standalone through the 0/1/2 exit wrapper.
    function _checkRoles(string memory name, string memory projectJson, bool rpcOk) private {
        if (!vm.keyExistsJson(projectJson, ".roles.token")) {
            _skip(string.concat("roles: no roles{} declared - bootstrap with make snapshot-chain CHAIN=", name));
            return;
        }
        // Anchor-vs-active drift (no RPC needed - a file compare). roles{} self-embeds its token/pool
        // anchors so the auditor is self-contained, but a later deploy can repoint addresses.active off
        // the anchored token; the auditor would then reconcile the STALE token clean (a false green).
        _warnAnchorDrift(name, projectJson, ".roles.token.address", "token", "roles.token.address");
        _warnAnchorDrift(name, projectJson, ".roles.pool.address", "tokenPool", "roles.pool.address");
        if (!rpcOk || !s_forked) {
            _skip("roles: authority reconciliation needs an RPC (no fork) - declared roles{} not checked against chain");
            return;
        }
        // Mirror every other rung in this file: a revert inside the auditor (a typo'd token.type, a
        // malformed declared address, a copied "0xGov..." placeholder) must degrade to a WARN, never
        // abort the whole doctor. RolesAuditor.auditJson is external, so the try/catch catches it.
        try (new RolesAuditor()).auditJson(name, projectJson) returns (RolesAuditor.Result memory rr) {
            // Roll the auditor tallies into the doctor verdict: a FAIL is a doctor FAIL. WARNs are
            // surfaced but NOT folded into the verdict, so routine complete:false honesty WARNs never
            // inflate the doctor's WARN count (the auditor already printed each WARN line).
            for (uint256 i = 0; i < rr.fails; i++) {
                s_fails++;
            }
            if (rr.fails == 0) {
                _pass(
                    string.concat(
                        "roles: declared roles{} reconciles clean (",
                        vm.toString(rr.passes),
                        " check(s) passed, ",
                        vm.toString(rr.warns),
                        " WARN, ",
                        vm.toString(rr.skips),
                        " SKIP)"
                    )
                );
            }
        } catch Error(string memory reason) {
            _warn(string.concat("roles: could not reconcile (", reason, ") - fix the roles{} declaration"));
        } catch {
            _warn("roles: could not reconcile (malformed roles{} - a declared address/value failed to parse)");
        }
    }

    /// @dev WARN (never FAIL) when a declared roles anchor differs from the store's `active.<role>`.
    /// Silent when the anchor is absent or the store has no active pointer (nothing to reconcile).
    function _warnAnchorDrift(
        string memory name,
        string memory projectJson,
        string memory anchorPath,
        string memory role,
        string memory label
    ) private {
        if (!vm.keyExistsJson(projectJson, anchorPath)) return;
        address anchor = vm.parseJsonAddress(projectJson, anchorPath);
        address active = RegistryWriter._read(name, role);
        if (active == address(0) || active == anchor) return;
        _warn(
            string.concat(
                "roles: ",
                label,
                " ",
                vm.toString(anchor),
                " != addresses.active.",
                role,
                " ",
                vm.toString(active),
                " - the audit reconciles the anchored value; re-anchor after a repoint: make snapshot-chain CHAIN=",
                name
            )
        );
    }

    function _checkLanesOnChain(
        string memory name,
        string memory,
        /*configJson*/
        string memory projectJson
    )
        private
    {
        if (!s_forked) {
            _skip("lanes: on-chain reconciliation needs an RPC (no fork) - declared lanes not checked against the pool");
            return;
        }
        address pool = RegistryWriter._read(name, "tokenPool");
        _reconcileLanesWithPool(name, projectJson, pool);
    }

    /// @dev The reconciliation core (fork + store resolution already done). Both the per-lane
    /// `lanes{}` policy and the pool-scoped `poolPolicy{}` block (ccvThreshold + finality) come from
    /// the project store. Every pool read goes through the probe so a weird pool degrades to a
    /// WARN/SKIP, never a hard revert of the doctor.
    function _reconcileLanesWithPool(string memory name, string memory projectJson, address pool) private {
        if (pool == address(0)) {
            _skip(
                string.concat(
                    "lanes: no tokenPool in ",
                    ProjectStore._display(name),
                    " - nothing to reconcile on-chain (make adopt-token CHAIN=",
                    name,
                    " TOKEN=<addr> TOKEN_POOL=<addr>, or deploy one: script/deploy/DeployBurnMintTokenPool.s.sol)"
                )
            );
            return;
        }
        (bool versionKnown, PoolVersions.Version version, string memory typeAndVersion) = PoolVersion._tryResolve(pool);
        if (!versionKnown) {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " reports \"",
                    typeAndVersion,
                    "\" - not a cataloged pool version; reconciling best effort (reads degrade, see docs/pool-versions.md)"
                )
            );
        }

        string[] memory declared =
            vm.keyExistsJson(projectJson, ".lanes") ? vm.parseJsonKeys(projectJson, ".lanes") : new string[](0);
        uint256 warnsBefore = s_warns;
        uint256 failsBefore = s_fails;
        // Pool-scoped policy (poolPolicy{} in the project store): reconciled once per chain, not per
        // lane - the additional-CCV threshold is pool-global on the hooks contract, and the allowed
        // finality config is pool-global on the pool itself.
        if (vm.keyExistsJson(projectJson, ".poolPolicy.ccvThreshold")) {
            _reconcileCcvThreshold(projectJson, pool, version);
        }
        if (vm.keyExistsJson(projectJson, ".poolPolicy.finality")) {
            _reconcileFinalityConfig(projectJson, pool, version);
        }
        uint64[] memory declaredSelectors = new uint64[](declared.length);
        for (uint256 i = 0; i < declared.length; i++) {
            declaredSelectors[i] = _checkDeclaredLaneOnChain(projectJson, pool, version, declared[i]);
        }
        bool reverseChecked = _checkOnChainLanesDeclared(name, pool, declaredSelectors);
        if (s_warns == warnsBefore && s_fails == failsBefore && reverseChecked) {
            _pass(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " agrees with lanes{} - ",
                    vm.toString(declared.length),
                    " declared lane(s) applied on-chain, every declared policy value matches, no undeclared on-chain lane"
                )
            );
        }
    }

    /// @dev Forward direction for ONE declared lane: the pool must support the declared remote
    /// selector, and the live outbound rate-limit bucket (version-dispatched getter) must match the
    /// declared policy. Returns the lane's selector (0 when unreadable) for the reverse check.
    function _checkDeclaredLaneOnChain(
        string memory json,
        address pool,
        PoolVersions.Version version,
        string memory remote
    ) private returns (uint64 selector) {
        string memory lanePath = string.concat(".lanes.", remote);
        // A lane entry without a remoteSelector is already a FAIL in the mesh rung; nothing to
        // reconcile on-chain for it.
        if (!vm.keyExistsJson(json, string.concat(lanePath, ".remoteSelector"))) return 0;
        selector = uint64(vm.parseJsonUint(json, string.concat(lanePath, ".remoteSelector")));

        bool supported;
        try s_probe.poolSupportsChain(pool, selector) returns (bool s) {
            supported = s;
        } catch {
            _warn(
                string.concat(
                    "lanes: could not read pool ",
                    vm.toString(pool),
                    " for lanes.",
                    remote,
                    " (selector ",
                    vm.toString(selector),
                    ") - RPC hiccup or non-standard pool; lane not reconciled"
                )
            );
            return selector;
        }
        if (!supported) {
            _warn(
                string.concat(
                    "lanes: lanes.",
                    remote,
                    " declared but not applied on-chain (pool.isSupportedChain(",
                    vm.toString(selector),
                    ") is false) - apply it: forge script script/setup/ApplyChainUpdates.s.sol"
                )
            );
            return selector;
        }
        _checkLanePolicy(json, pool, version, remote, selector);
    }

    /// @dev The declared policy blocks of one applied lane, against the live pool. Always: the core
    /// outbound bucket (`capacity`/`rate`). Optional, reconciled ONLY when declared (absent fields
    /// are undeclared, never defaulted): the `inbound{}` bucket, and the `v2{}` block (fast-finality
    /// buckets + per-lane fee config + per-lane ccv), which needs a 2.0.0 pool - declared against a
    /// cataloged earlier version it is a FAIL naming the mismatch (the declaration can never
    /// converge), declared against an unrecognized version a WARN; never a read attempt either way.
    function _checkLanePolicy(
        string memory json,
        address pool,
        PoolVersions.Version version,
        string memory remote,
        uint64 selector
    ) private {
        string memory lanePath = string.concat(".lanes.", remote);
        _reconcileBucket(json, lanePath, pool, version, remote, selector, "outbound");
        if (vm.keyExistsJson(json, string.concat(lanePath, ".inbound"))) {
            _reconcileBucket(json, string.concat(lanePath, ".inbound"), pool, version, remote, selector, "inbound");
        }
        if (!vm.keyExistsJson(json, string.concat(lanePath, ".v2"))) return;
        if (version < PoolVersions.Version.V2_0_0) {
            (,, string memory typeAndVersion) = PoolVersion._tryResolve(pool);
            string memory gate = string.concat(
                "lanes: lanes.",
                remote,
                " declares a v2{} block but pool ",
                vm.toString(pool),
                " reports \"",
                typeAndVersion,
                "\" - the v2 lane surface (fast finality, fee config, ccv) needs a 2.0.0 pool; block not reconciled"
            );
            // A cataloged pre-2.0.0 pool can never satisfy a v2 declaration: FAIL by name (fix the
            // declaration or migrate the pool). An uncataloged version is degraded visibility, not
            // proven incompatibility: WARN per the reads-degrade doctrine.
            if (version != PoolVersions.Version.UNKNOWN) {
                _fail(string.concat(gate, "; fix the declaration or migrate the pool"));
            } else {
                _warn(gate);
            }
            return;
        }
        string memory ftfPath = string.concat(lanePath, ".v2.fastFinality");
        if (vm.keyExistsJson(json, string.concat(ftfPath, ".outbound"))) {
            _reconcileBucket(
                json, string.concat(ftfPath, ".outbound"), pool, version, remote, selector, "fast-finality outbound"
            );
        }
        if (vm.keyExistsJson(json, string.concat(ftfPath, ".inbound"))) {
            _reconcileBucket(
                json, string.concat(ftfPath, ".inbound"), pool, version, remote, selector, "fast-finality inbound"
            );
        }
        if (vm.keyExistsJson(json, string.concat(lanePath, ".v2.feeConfig"))) {
            _reconcileFeeConfig(json, string.concat(lanePath, ".v2.feeConfig"), pool, remote, selector);
        }
        if (vm.keyExistsJson(json, string.concat(lanePath, ".v2.ccv"))) {
            _reconcileCCVConfig(json, string.concat(lanePath, ".v2.ccv"), pool, remote, selector);
        }
    }

    /// @dev Compares ONE declared bucket (capacity/rate at `declPath`; enabled iff either is
    /// non-zero) to the live bucket for its direction. `label` names the bucket in every message:
    /// "outbound" (the core policy), "inbound", "fast-finality outbound", "fast-finality inbound".
    /// Drift is a FAIL naming the bucket: the declaration is the intent, so an emergency throttle is
    /// recorded by updating the declaration (the git diff documents it). An unanswered getter stays
    /// WARN (degraded visibility, not proven drift).
    function _reconcileBucket(
        string memory json,
        string memory declPath,
        address pool,
        PoolVersions.Version version,
        string memory remote,
        uint64 selector,
        string memory label
    ) private {
        (uint256 capacity, uint256 rate) = _declaredBucket(json, declPath);
        bool enabled = capacity != 0 || rate != 0;
        bool inbound = _endsWith(label, "inbound");
        bool fastFinality = _startsWith(label, "fast-finality");

        RateLimiter.TokenBucket memory live;
        try s_probe.poolBucket(pool, version, selector, inbound, fastFinality) returns (
            RateLimiter.TokenBucket memory b
        ) {
            live = b;
        } catch {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer the ",
                    label,
                    " rate-limit getter for lanes.",
                    remote,
                    " - declared policy not reconciled"
                )
            );
            return;
        }
        if (live.isEnabled == enabled && (!enabled || (live.capacity == capacity && live.rate == rate))) return;
        _fail(
            string.concat(
                "lanes: lanes.",
                remote,
                " ",
                label,
                " rate-limit drift - declared enabled=",
                enabled ? "true" : "false",
                " capacity=",
                vm.toString(capacity),
                " rate=",
                vm.toString(rate),
                " but on-chain enabled=",
                live.isEnabled ? "true" : "false",
                " capacity=",
                vm.toString(live.capacity),
                " rate=",
                vm.toString(live.rate),
                " - re-apply the policy (ApplyChainUpdates/UpdateRateLimiters) or update the declaration to the live values"
            )
        );
    }

    /// @dev Declared (capacity, rate) at `declPath`; a missing key reads as 0 so a partial block
    /// still reconciles deterministically (the schema documents both fields).
    function _declaredBucket(string memory json, string memory declPath)
        private
        view
        returns (uint256 capacity, uint256 rate)
    {
        string memory capKey = string.concat(declPath, ".capacity");
        string memory rateKey = string.concat(declPath, ".rate");
        capacity = vm.keyExistsJson(json, capKey) ? vm.parseJsonUint(json, capKey) : 0;
        rate = vm.keyExistsJson(json, rateKey) ? vm.parseJsonUint(json, rateKey) : 0;
    }

    /// @dev Compares the declared per-lane fee config (2.0.0 pools) to the live
    /// `getTokenTransferFeeConfig`. A declared block means an ENABLED on-chain config (the pool
    /// refuses to store a disabled one), so a declared-but-live-disabled config is a FAIL like any
    /// other drift; each declared field is compared individually (one FAIL line per drifting field)
    /// and an undeclared field is not reconciled. An unanswered getter stays WARN.
    function _reconcileFeeConfig(
        string memory json,
        string memory declPath,
        address pool,
        string memory remote,
        uint64 selector
    ) private {
        IPoolV2.TokenTransferFeeConfig memory live;
        try s_probe.poolFeeConfig(pool, selector) returns (IPoolV2.TokenTransferFeeConfig memory f) {
            live = f;
        } catch {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer getTokenTransferFeeConfig for lanes.",
                    remote,
                    " - v2.feeConfig not reconciled"
                )
            );
            return;
        }
        if (!live.isEnabled) {
            _fail(
                string.concat(
                    "lanes: lanes.",
                    remote,
                    " v2.feeConfig declared but the pool has no enabled fee config on-chain for selector ",
                    vm.toString(selector),
                    " - apply it (script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol) or remove the declaration"
                )
            );
            return;
        }
        _reconcileFeeField(json, declPath, remote, "destGasOverhead", live.destGasOverhead);
        _reconcileFeeField(json, declPath, remote, "destBytesOverhead", live.destBytesOverhead);
        _reconcileFeeField(json, declPath, remote, "finalityFeeUSDCents", live.finalityFeeUSDCents);
        _reconcileFeeField(json, declPath, remote, "fastFinalityFeeUSDCents", live.fastFinalityFeeUSDCents);
        _reconcileFeeField(json, declPath, remote, "finalityTransferFeeBps", live.finalityTransferFeeBps);
        _reconcileFeeField(json, declPath, remote, "fastFinalityTransferFeeBps", live.fastFinalityTransferFeeBps);
    }

    /// @dev One declared fee-config field vs its live value (skipped when undeclared).
    function _reconcileFeeField(
        string memory json,
        string memory declPath,
        string memory remote,
        string memory field,
        uint256 liveValue
    ) private {
        string memory key = string.concat(declPath, ".", field);
        if (!vm.keyExistsJson(json, key)) return;
        uint256 declaredValue = vm.parseJsonUint(json, key);
        if (declaredValue == liveValue) return;
        _fail(
            string.concat(
                "lanes: lanes.",
                remote,
                " v2.feeConfig.",
                field,
                " drift - declared ",
                vm.toString(declaredValue),
                " but on-chain ",
                vm.toString(liveValue),
                " - re-apply (script/configure/fee-config/UpdateTokenTransferFeeConfig.s.sol) or update the declaration"
            )
        );
    }

    /// @dev Compares the declared per-lane CCV config (2.0.0 pools with an AdvancedPoolHooks wired) to
    /// the live `getCCVConfig`. CCVs live on the hooks contract, not the pool: a 2.0.0 pool with no
    /// hooks wired can never satisfy a declared v2.ccv block, so it is a FAIL of the same shape as
    /// the v2-block-on-a-cataloged-1.x-pool gate. Each declared verifier array is compared as a SET
    /// (order-insensitive - a reordering of the same CCVs is not drift) and a mismatch is a FAIL
    /// naming the array (a drifted verifier set silently changes what attestations the lane
    /// requires); an undeclared array is not reconciled. Any read failure degrades to a WARN, never
    /// a FAIL or a revert of the doctor.
    function _reconcileCCVConfig(
        string memory json,
        string memory declPath,
        address pool,
        string memory remote,
        uint64 selector
    ) private {
        address hooks;
        try s_probe.poolHooks(pool) returns (address h) {
            hooks = h;
        } catch {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer getAdvancedPoolHooks for lanes.",
                    remote,
                    " - v2.ccv not reconciled"
                )
            );
            return;
        }
        if (hooks == address(0)) {
            _fail(
                string.concat(
                    "lanes: lanes.",
                    remote,
                    " declares a v2.ccv block but pool ",
                    vm.toString(pool),
                    " has no AdvancedPoolHooks wired - wire hooks (script/configure/allowlist/DeployAdvancedPoolHooks.s.sol) or remove the declaration"
                )
            );
            return;
        }

        AdvancedPoolHooks.CCVConfig memory live;
        try s_probe.hooksCCVConfig(hooks, selector) returns (AdvancedPoolHooks.CCVConfig memory c) {
            live = c;
        } catch {
            _warn(
                string.concat(
                    "lanes: hooks ",
                    vm.toString(hooks),
                    " does not answer getCCVConfig for lanes.",
                    remote,
                    " - v2.ccv not reconciled"
                )
            );
            return;
        }
        _reconcileCCVField(json, declPath, remote, "outboundCCVs", live.outboundCCVs);
        _reconcileCCVField(json, declPath, remote, "thresholdOutboundCCVs", live.thresholdOutboundCCVs);
        _reconcileCCVField(json, declPath, remote, "inboundCCVs", live.inboundCCVs);
        _reconcileCCVField(json, declPath, remote, "thresholdInboundCCVs", live.thresholdInboundCCVs);
    }

    /// @dev One declared CCV array vs its live value (skipped when undeclared). SET comparison, so a
    /// re-ordering of the same verifier set is not spurious drift.
    function _reconcileCCVField(
        string memory json,
        string memory declPath,
        string memory remote,
        string memory field,
        address[] memory live
    ) private {
        string memory key = string.concat(declPath, ".", field);
        if (!vm.keyExistsJson(json, key)) return;
        address[] memory declared = vm.parseJsonAddressArray(json, key);
        if (_sameAddressSet(declared, live)) return;
        _fail(
            string.concat(
                "lanes: lanes.",
                remote,
                " v2.ccv.",
                field,
                " drift - declared ",
                _addrArrayToString(declared),
                " but on-chain ",
                _addrArrayToString(live),
                " - re-apply (script/configure/ccv/UpdateCCVConfig.s.sol) or update the declaration"
            )
        );
    }

    /// @dev The pool-scoped (pool-global) additional-CCV threshold, declared at
    /// `poolPolicy.ccvThreshold` in the project store, vs the live `getThresholdAmount`. Needs a
    /// 2.0.0 pool with an AdvancedPoolHooks wired: a cataloged pre-2.0.0 pool or an unwired 2.0.0
    /// pool can never satisfy the declaration, so both are FAILs naming the fix; an uncataloged
    /// version and any unanswered read stay WARN. Drift is a FAIL naming the field.
    function _reconcileCcvThreshold(string memory json, address pool, PoolVersions.Version version) private {
        if (version < PoolVersions.Version.V2_0_0) {
            (,, string memory typeAndVersion) = PoolVersion._tryResolve(pool);
            string memory gate = string.concat(
                "lanes: poolPolicy.ccvThreshold declared but pool ",
                vm.toString(pool),
                " reports \"",
                typeAndVersion,
                "\" - the pool-global CCV threshold needs a 2.0.0 pool; not reconciled"
            );
            if (version != PoolVersions.Version.UNKNOWN) {
                _fail(string.concat(gate, "; fix the declaration or migrate the pool"));
            } else {
                _warn(gate);
            }
            return;
        }
        address hooks;
        try s_probe.poolHooks(pool) returns (address h) {
            hooks = h;
        } catch {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer getAdvancedPoolHooks - poolPolicy.ccvThreshold not reconciled"
                )
            );
            return;
        }
        if (hooks == address(0)) {
            _fail(
                string.concat(
                    "lanes: poolPolicy.ccvThreshold declared but pool ",
                    vm.toString(pool),
                    " has no AdvancedPoolHooks wired - wire hooks (script/configure/allowlist/DeployAdvancedPoolHooks.s.sol) or remove the declaration"
                )
            );
            return;
        }
        uint256 live;
        try s_probe.hooksThreshold(hooks) returns (uint256 t) {
            live = t;
        } catch {
            _warn(
                string.concat(
                    "lanes: hooks ",
                    vm.toString(hooks),
                    " does not answer getThresholdAmount - poolPolicy.ccvThreshold not reconciled"
                )
            );
            return;
        }
        uint256 declared = vm.parseJsonUint(json, ".poolPolicy.ccvThreshold");
        if (declared == live) return;
        _fail(
            string.concat(
                "lanes: poolPolicy.ccvThreshold drift - declared ",
                vm.toString(declared),
                " but on-chain ",
                vm.toString(live),
                " - re-apply (script/configure/ccv/UpdateCCVConfig.s.sol) or update the declaration"
            )
        );
    }

    /// @dev The pool-scoped allowed-finality config, declared in mode terms at `poolPolicy.finality`
    /// in the project store ({blockDepth?, waitForSafe?}; an empty block declares the default
    /// WAIT_FOR_FINALITY, i.e. fast finality disabled), vs the live `getAllowedFinalityConfig`.
    /// Needs a 2.0.0 pool: a cataloged pre-2.0.0 pool can never satisfy the declaration (FAIL); an
    /// uncataloged version and an unanswered read stay WARN. Drift is a FAIL printing both sides raw
    /// (bytes4) plus decoded, so the operator sees the meaning next to the hex.
    function _reconcileFinalityConfig(string memory json, address pool, PoolVersions.Version version) private {
        if (version < PoolVersions.Version.V2_0_0 && version != PoolVersions.Version.UNKNOWN) {
            (,, string memory typeAndVersion) = PoolVersion._tryResolve(pool);
            _fail(
                string.concat(
                    "lanes: poolPolicy.finality declared but pool ",
                    vm.toString(pool),
                    " reports \"",
                    typeAndVersion,
                    "\" - the allowed finality config needs a 2.0.0 pool; fix the declaration or migrate the pool"
                )
            );
            return;
        }
        bytes4 live;
        try s_probe.poolAllowedFinality(pool) returns (bytes4 f) {
            live = f;
        } catch {
            _warn(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer getAllowedFinalityConfig - poolPolicy.finality not reconciled"
                )
            );
            return;
        }
        bytes4 declared;
        try s_probe.parseDeclaredFinality(json) returns (bytes4 d) {
            declared = d;
        } catch Error(string memory reason) {
            _fail(string.concat("lanes: malformed poolPolicy.finality declaration (", reason, ") - fix the hand edit"));
            return;
        } catch {
            _fail("lanes: malformed poolPolicy.finality declaration (a value failed to parse) - fix the hand edit");
            return;
        }
        if (declared == live) return;
        _fail(
            string.concat(
                "lanes: poolPolicy.finality drift - declared ",
                vm.toString(abi.encodePacked(declared)),
                " (",
                FinalityConfigUtils._decodeModeLabel(declared),
                ") but on-chain ",
                vm.toString(abi.encodePacked(live)),
                " (",
                FinalityConfigUtils._decodeModeLabel(live),
                ") - re-apply (script/configure/finality-config/SetFinalityConfig.s.sol) or update the declaration"
            )
        );
    }

    /// @dev SET equality (order-insensitive) of two address arrays: equal length and mutual
    /// containment - so a re-ordering of the same CCV set is not spurious drift.
    function _sameAddressSet(address[] memory a, address[] memory b) private pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (!_containsAddress(b, a[i])) return false;
        }
        for (uint256 i = 0; i < b.length; i++) {
            if (!_containsAddress(a, b[i])) return false;
        }
        return true;
    }

    function _containsAddress(address[] memory arr, address x) private pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == x) return true;
        }
        return false;
    }

    /// @dev Compact "[0xA,0xB]" rendering for the CCV drift WARN (in the value's order).
    function _addrArrayToString(address[] memory arr) private pure returns (string memory out) {
        out = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            out = string.concat(out, i == 0 ? "" : ",", vm.toString(arr[i]));
        }
        out = string.concat(out, "]");
    }

    /// @dev String helpers for the bucket-label -> direction mapping (labels are internal constants,
    /// so prefix/suffix matching is exact by construction).
    function _startsWith(string memory s, string memory prefix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        if (p.length > b.length) return false;
        for (uint256 i = 0; i < p.length; i++) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory s, string memory suffix) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory x = bytes(suffix);
        if (x.length > b.length) return false;
        for (uint256 i = 0; i < x.length; i++) {
            if (b[b.length - x.length + i] != x[i]) return false;
        }
        return true;
    }

    /// @dev Reverse direction: every selector the pool supports on-chain must be declared in
    /// lanes{}. `getSupportedChains()` exists on every cataloged version (1.5.0 through 2.0.0);
    /// a pool that does not answer it degrades this half to a SKIP. Returns whether the reverse
    /// check actually ran (gates the rung's PASS line).
    function _checkOnChainLanesDeclared(string memory name, address pool, uint64[] memory declaredSelectors)
        private
        returns (bool reverseChecked)
    {
        uint64[] memory onChain;
        try s_probe.poolSupportedChains(pool) returns (uint64[] memory chains) {
            onChain = chains;
        } catch {
            _skip(
                string.concat(
                    "lanes: pool ",
                    vm.toString(pool),
                    " does not answer getSupportedChains() - reverse (on-chain -> declared) check skipped"
                )
            );
            return false;
        }
        for (uint256 i = 0; i < onChain.length; i++) {
            bool isDeclared = false;
            for (uint256 j = 0; j < declaredSelectors.length; j++) {
                if (declaredSelectors[j] == onChain[i]) {
                    isDeclared = true;
                    break;
                }
            }
            if (isDeclared) continue;
            string memory remoteName = _chainNameBySelector(onChain[i]);
            if (bytes(remoteName).length == 0) {
                _warn(
                    string.concat(
                        "lanes: on-chain lane to selector ",
                        vm.toString(onChain[i]),
                        " not declared in lanes{} (no config/chains entry for that selector - make add-chain first, then make add-lane LOCAL=",
                        name,
                        ")"
                    )
                );
            } else {
                _warn(
                    string.concat(
                        "lanes: on-chain lane to ",
                        remoteName,
                        " (",
                        vm.toString(onChain[i]),
                        ") not declared in lanes{} - declare it: make add-lane LOCAL=",
                        name,
                        " REMOTE=",
                        remoteName,
                        " CAPACITY=<wei> RATE=<wei>"
                    )
                );
            }
        }
        return true;
    }

    /// @dev Resolves a chainSelector to its config/chains basename ("" when no config declares it).
    /// Reads go through the probe so a file removed/mid-write by a concurrent test is skipped.
    function _chainNameBySelector(uint64 selector) private view returns (string memory) {
        Vm.DirEntry[] memory entries = vm.readDir("config/chains");
        for (uint256 i = 0; i < entries.length; i++) {
            string memory other = _jsonBasename(entries[i].path);
            if (bytes(other).length == 0) continue;
            string memory oj;
            try s_probe.readFileFor(entries[i].path) returns (string memory data) {
                oj = data;
            } catch {
                continue;
            }
            try s_probe.parseQuotedDecimals(oj) returns (string memory, string memory sel) {
                if (keccak256(bytes(sel)) == keccak256(bytes(vm.toString(selector)))) return other;
            } catch {
                continue;
            }
        }
        return "";
    }

    /// @notice Test hook: runs ONLY the on-chain lane reconciliation for `name` against `pool` on
    /// the currently-selected fork and returns `(fails, warns)`. Lets a fork test assert the rung's
    /// severity contract (declared-vs-live drift FAILs naming the field; forward-intent, undeclared
    /// on-chain lanes, and unanswered reads stay WARN) and the no-pool SKIP without the full ffi/API
    /// doctor run. Not used by any production path.
    function checkLanesOnChainForTest(string memory name, address pool)
        public
        returns (uint256 failsOut, uint256 warnsOut)
    {
        s_forked = true;
        s_probe = new ChainProbe();
        _reconcileLanesWithPool(name, _readProject(name), pool);
        return (s_fails, s_warns);
    }
}
