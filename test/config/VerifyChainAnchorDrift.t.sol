// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title VerifyChainAnchorDriftTest - the roles anchor-drift WARN (`_warnAnchorDrift`, offline)
/// @notice The doctor's ROLES rung self-embeds each `roles.<x>.address` anchor so the auditor is
/// self-contained, but a later deploy can repoint `addresses.active.<role>` off the anchored token -
/// the auditor would then reconcile the STALE anchored value clean (a false green). `_warnAnchorDrift`
/// catches that: a declared anchor that DIVERGES from the store's active pointer emits exactly one WARN
/// (naming both addresses + `REANCHOR=true make snapshot-chain`), while a matching anchor, an absent
/// anchor, or a store with no active pointer stays silent. It is WARN-only (never FAIL) and needs no RPC - a pure
/// file compare - so this suite pins the (fails, warns) contract as a unit test via
/// `warnAnchorDriftForTest`, which runs ONLY that check. Each test writes its own uniquely-named scratch
/// project file (suites run in parallel and share the filesystem) and cleans it in setUp() (revert-safe).
contract VerifyChainAnchorDriftTest is Test {
    // Two distinct, deterministic addresses: the declared anchor vs the store's active pointer.
    address internal constant ANCHOR = 0x00000000000000000000000000000000000000AA;
    address internal constant ACTIVE = 0x00000000000000000000000000000000000000bb;

    string internal constant SEL_MATCH = "zz-scratch-anchordrift-match";
    string internal constant SEL_NOACTIVE = "zz-scratch-anchordrift-noactive";
    string internal constant SEL_NOANCHOR = "zz-scratch-anchordrift-noanchor";
    string internal constant SEL_DRIFT = "zz-scratch-anchordrift-drift";
    string internal constant SEL_ZERO = "zz-scratch-anchordrift-zero";
    string internal constant SEL_MALFORMED = "zz-scratch-anchordrift-malformed";
    string internal constant SEL_REUSE = "zz-scratch-anchordrift-reuse";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[7] memory sels = [SEL_MATCH, SEL_NOACTIVE, SEL_NOANCHOR, SEL_DRIFT, SEL_ZERO, SEL_MALFORMED, SEL_REUSE];
        for (uint256 i = 0; i < sels.length; i++) {
            string memory p = ProjectStore._path(sels[i]);
            if (vm.exists(p)) vm.removeFile(p);
        }
    }

    /// @dev Per-name variant for end-of-test cleanup (a test removes ONLY the file it owns; suite
    /// siblings run in parallel).
    function _clean(string memory sel) private {
        string memory p = ProjectStore._path(sel);
        if (vm.exists(p)) vm.removeFile(p);
    }

    /// @dev Writes a schema-3 project store for `name` with the given `active{}` and `roles{}` bodies
    /// (each a comma-free `"key":value` fragment, or "" for an empty object). The anchor-drift check
    /// reads `.roles.<x>.address` (the declared anchor) and `.addresses.active.<role>` (the store), so
    /// only those two subtrees carry content here; `lanes{}`/`deployments{}` stay empty.
    function _writeProject(string memory name, string memory activeBody, string memory rolesBody) internal {
        string memory json = string.concat(
            "{\"addresses\":{\"active\":{",
            activeBody,
            "},\"deployments\":{}},\"lanes\":{},\"roles\":{",
            rolesBody,
            "},\"schema\":3}"
        );
        vm.writeFile(ProjectStore._path(name), json);
    }

    /// @dev `"<role>":"<addr>"` - an active-pointer fragment.
    function _active(string memory role, address addr) internal pure returns (string memory) {
        return string.concat("\"", role, "\":\"", vm.toString(addr), "\"");
    }

    /// @dev `"<key>":{"address":"<addr>"}` - a roles anchor fragment (`token`/`pool`).
    function _anchor(string memory key, address addr) internal pure returns (string memory) {
        return string.concat("\"", key, "\":{\"address\":\"", vm.toString(addr), "\"}");
    }

    // ------------------------------------------------------------ clean: anchor == active → silent

    /// @dev Both anchors match their active pointer: nothing has repointed, so the check is SILENT
    /// (0 FAIL, 0 WARN). This is the healthy steady state right after `make snapshot-chain`.
    function test_AnchorDrift_AnchorsMatchActive_Silent() public {
        _writeProject(
            SEL_MATCH,
            string.concat(_active("token", ANCHOR), ",", _active("tokenPool", ACTIVE)),
            string.concat(_anchor("token", ANCHOR), ",", _anchor("pool", ACTIVE))
        );
        (uint256 fails, uint256 warns) = new VerifyChain().warnAnchorDriftForTest(SEL_MATCH);
        assertEq(fails, 0, "anchor drift is WARN-only, never FAIL");
        assertEq(warns, 0, "matching anchors must be silent");
        _clean(SEL_MATCH);
    }

    // ------------------------------------------------------------ clean: no active pointer → silent

    /// @dev The anchor is declared but the store has NO active pointer (nothing has been deployed/
    /// recorded yet): there is nothing to reconcile against, so the check is SILENT. `active == 0` is
    /// the explicit early-return in `_warnAnchorDrift`.
    function test_AnchorDrift_NoActivePointer_Silent() public {
        _writeProject(SEL_NOACTIVE, "", _anchor("token", ANCHOR));
        (uint256 fails, uint256 warns) = new VerifyChain().warnAnchorDriftForTest(SEL_NOACTIVE);
        assertEq(fails, 0, "no-active-pointer must never FAIL");
        assertEq(warns, 0, "an anchor with no active pointer to compare against is silent");
        _clean(SEL_NOACTIVE);
    }

    // ------------------------------------------------------------ clean: anchor absent → silent

    /// @dev The store carries an active pointer but the `roles{}` block declares NO anchor: absent
    /// anchor → nothing to reconcile → SILENT (the `keyExistsJson` early-return).
    function test_AnchorDrift_AnchorAbsent_Silent() public {
        _writeProject(SEL_NOANCHOR, _active("token", ACTIVE), "");
        (uint256 fails, uint256 warns) = new VerifyChain().warnAnchorDriftForTest(SEL_NOANCHOR);
        assertEq(fails, 0, "an absent anchor must never FAIL");
        assertEq(warns, 0, "no declared anchor means nothing to reconcile - silent");
        _clean(SEL_NOANCHOR);
    }

    // ------------------------------------------------------------ induced: anchor != active → 1 WARN

    /// @dev INDUCED DRIFT: `roles.token.address = ANCHOR` but `addresses.active.token = ACTIVE` (a
    /// repoint after the snapshot). Exactly one WARN, zero FAIL. Only the token anchor is declared, so
    /// the pool half stays silent - proving the single WARN is the token divergence alone. The WARN
    /// message text (both addresses + `REANCHOR=true make snapshot-chain CHAIN=<name>`) is composed
    /// inline in `_warnAnchorDrift` and is source-pinned; console.log output is not in-test capturable, so the
    /// contract asserted here is the (fails, warns) tally, exactly as the other doctor-rung suites do.
    function test_AnchorDrift_TokenAnchorDivergesFromActive_OneWarn() public {
        _writeProject(SEL_DRIFT, _active("token", ACTIVE), _anchor("token", ANCHOR));
        (uint256 fails, uint256 warns) = new VerifyChain().warnAnchorDriftForTest(SEL_DRIFT);
        assertEq(fails, 0, "a drifted anchor must never FAIL (WARN-only)");
        assertEq(warns, 1, "a token anchor diverging from active.token must emit exactly one WARN");
        _clean(SEL_DRIFT);
    }

    /// A zero anchor is a declaration the auditor cannot use: `RolesAuditor` counts a present-but-zero
    /// key as declared, gates every check behind a non-zero token, and reports "reconciles clean"
    /// having audited nothing. It must be NAMED, and not with the drift remedy - a plain
    /// `snapshot-chain` does not refuse a zero anchor, it resolves past it.
    function test_ZeroAnchor_WarnsOnItsOwnTerms() public {
        _writeProject(SEL_ZERO, _active("token", ACTIVE), _anchor("token", address(0)));
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.warnAnchorDriftForTest(SEL_ZERO);
        assertEq(fails, 0, "a zero anchor is a WARN, never a FAIL");
        assertEq(warns, 1, "a zero anchor must be named, not silently skipped");
        // The count alone proves nothing: with the zero branch removed this case falls through to the
        // DRIFT warning, which is also exactly one WARN. Assert WHICH warning fired.
        string memory got = vc.lastWarnForTest();
        assertTrue(_contains(got, "is the zero address"), "must name the zero anchor as the problem");
        assertTrue(
            !_contains(got, "refuses a stale anchor"), "must not quote the drift remedy - snapshot does not refuse here"
        );
        _clean(SEL_ZERO);
    }

    /// This rung runs OUTSIDE the try/catch that wraps the auditor, so a bare parse of a malformed
    /// anchor took the whole doctor down - no verdict, no exit code - on a store the snapshot half
    /// refuses cleanly. It must degrade to a WARN.
    function test_MalformedAnchor_WarnsInsteadOfAbortingTheDoctor() public {
        vm.writeFile(
            ProjectStore._path(SEL_MALFORMED),
            string.concat(
                "{\"addresses\":{\"active\":{",
                _active("token", ACTIVE),
                "},\"deployments\":{}},\"lanes\":{},\"roles\":{\"token\":{\"address\":\"\"}},\"schema\":3}"
            )
        );
        VerifyChain vc = new VerifyChain();
        (uint256 fails, uint256 warns) = vc.warnAnchorDriftForTest(SEL_MALFORMED);
        assertEq(fails, 0, "a malformed anchor is a WARN, never a FAIL");
        assertEq(warns, 1, "a malformed anchor must degrade to one WARN, not abort the run");
        assertTrue(
            _contains(vc.lastWarnForTest(), "is not an address"), "must name the unparseable anchor as the problem"
        );
        _clean(SEL_MALFORMED);
    }

    /// @dev Substring test: the WARN text is assembled at runtime, so a full-string equality would pin
    /// wording rather than meaning.
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

    /// The hook resets the tally, so every call reports its OWN store. Without that a second call carries
    /// the FIRST store's verdict - a zero-anchor assertion would then pass against a healthy store.
    function test_HookResetsBetweenCalls() public {
        _writeProject(SEL_ZERO, _active("token", ACTIVE), _anchor("token", address(0)));
        _writeProject(SEL_REUSE, _active("token", ACTIVE), _anchor("token", ACTIVE));
        VerifyChain vc = new VerifyChain();
        (, uint256 firstWarns) = vc.warnAnchorDriftForTest(SEL_ZERO);
        assertEq(firstWarns, 1, "the zero-anchor store warns once");
        (uint256 fails, uint256 warns) = vc.warnAnchorDriftForTest(SEL_REUSE);
        assertEq(warns, 0, "an agreeing anchor must report zero warns even on a reused instance");
        assertEq(fails, 0, "and zero fails");
        assertEq(vc.lastWarnForTest(), "", "the previous store's message must not survive the call");
        _clean(SEL_ZERO);
        _clean(SEL_REUSE);
    }
}
