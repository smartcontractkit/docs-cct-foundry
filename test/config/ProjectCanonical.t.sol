// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @title ProjectCanonicalTest — area B (canonical / zero-diff golden)
/// @notice Pins the `project/*.json` CANONICAL FORM the whole store depends on: forge
/// `vm.writeJson`'s deterministic output — keys SORTED at every nesting level, 2-space indent, and
/// **NO trailing newline**. A downstream fork tracks `project/`, so a no-op re-write MUST produce a
/// zero git diff; that is exactly `writer output == jq --indent 2 -S` with the trailing newline
/// normalized. Two independent goldens:
///   1. an ffi-FREE byte-exact pin (always runs in CI) against a hand-written canonical literal, and
///   2. an ffi-gated cross-check against `jq --indent 2 -S` (the acceptance-listed equivalence), which
///      SKIPs with a NAMED reason when ffi is off (the default profile) instead of failing.
/// Plus no-op-re-write byte-identity (the shasum idiom, no `make` in the loop) and the committed
/// example's canonicality.
contract ProjectCanonicalTest is Test {
    string internal constant SEL_BYTE = "zz-scratch-canon-byte";
    string internal constant SEL_JQ = "zz-scratch-canon-jq";
    string internal constant SEL_NOOP = "zz-scratch-canon-noop";
    string internal constant SEL_EDGE = "zz-scratch-canon-edge";
    string internal constant SEL_EXAMPLE = "zz-scratch-canon-example";
    string internal constant SEL_POLICY = "zz-scratch-canon-poolpolicy";

    address internal constant TOKEN = address(0x1111111111111111111111111111111111111111);
    address internal constant POOL = address(0x2222222222222222222222222222222222222222);
    // A mixed-case (EIP-55 checksummed) hex value — the writer must emit it verbatim, not lowercase it.
    address internal constant MIXED = address(0xabCDeF0123456789AbcdEf0123456789aBCDEF01);

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        ProjectScratch.clean(SEL_BYTE);
        ProjectScratch.clean(SEL_JQ);
        ProjectScratch.clean(SEL_NOOP);
        ProjectScratch.clean(SEL_EDGE);
        ProjectScratch.clean(SEL_EXAMPLE);
        ProjectScratch.clean(SEL_POLICY);
    }

    /// @dev The exact canonical bytes a single `token` record produces (2-space, sorted, no trailing
    /// newline). Captured from `vm.writeJson` and pinned as a literal so any change to the writer's
    /// serialization (spacing, key order, a stray trailing newline) is a hard failure, not a silent
    /// git-diff churn on the fork that tracks `project/`.
    function test_WriterOutput_ByteCanonical() public {
        RegistryWriter.recordDeterministic(SEL_BYTE, "token", "SYM_Token", TOKEN);
        string memory got = vm.readFile(ProjectStore.path(SEL_BYTE));
        string memory expected = string.concat(
            "{\n",
            '  "addresses": {\n',
            '    "active": {\n',
            '      "token": "0x1111111111111111111111111111111111111111"\n',
            "    },\n",
            '    "deployments": {\n',
            '      "SYM_Token": "0x1111111111111111111111111111111111111111"\n',
            "    }\n",
            "  },\n",
            '  "lanes": {},\n',
            '  "roles": {},\n',
            '  "schema": 3\n',
            "}"
        );
        assertEq(got, expected, "writer output is not the 2-space sorted no-trailing-newline canonical form");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "canonical project file must have NO trailing newline");
        ProjectScratch.clean(SEL_BYTE);
    }

    /// @dev The acceptance-listed equivalence: writer output == `jq --indent 2 -S .` with the trailing
    /// newline normalized. `$(cat f) == $(jq --indent 2 -S . f)` strips trailing newlines on both sides;
    /// here we compare `readFile` (no trailing NL) to `jq` stdout with any trailing "\n" trimmed. ffi is
    /// off in the default profile, so a jq/ffi-unavailable run SKIPs with a NAMED reason.
    function test_WriterOutput_MatchesJqSortedIndent2_FfiGated() public {
        // Probe ffi availability BEFORE any write: a mid-body vm.skip strands the scratch file
        // (a plain `forge test` has ffi off, and the CI residue gate catches the leak).
        _skipUnlessFfi();
        RegistryWriter.recordDeterministic(SEL_JQ, "token", "SYM_Token", TOKEN);
        RegistryWriter.recordDeterministic(SEL_JQ, "tokenPool", "SYM_BurnMintTokenPool_2.0.0", POOL);
        string memory path = ProjectStore.path(SEL_JQ);
        string memory got = vm.readFile(path);

        string[] memory cmd = new string[](5);
        cmd[0] = "jq";
        cmd[1] = "--indent";
        cmd[2] = "2";
        cmd[3] = "-S";
        cmd[4] = "."; // jq reads the file path appended below
        // vm.ffi requires ffi=true; SKIP (named) when unavailable rather than fail the offline CI job.
        string[] memory full = new string[](6);
        for (uint256 i = 0; i < 5; i++) {
            full[i] = cmd[i];
        }
        full[5] = path;
        try this.runFfi(full) returns (bytes memory out) {
            string memory jqOut = _trimTrailingNewline(string(out));
            assertEq(got, jqOut, "writer output != jq --indent 2 -S (newline-normalized): NOT canonical");
        } catch {
            emit log_string("SKIP: ffi/jq unavailable (default profile has ffi off) - jq golden not run");
            vm.skip(true);
        }
        ProjectScratch.clean(SEL_JQ);
    }

    /// @dev External wrapper so the ffi call can be `try`-caught (an internal ffi revert is not catchable).
    function runFfi(string[] calldata cmd) external returns (bytes memory) {
        return vm.ffi(cmd);
    }

    /// @dev Named SKIP unless ffi is available - probed with a trivial command so the caller can gate
    /// BEFORE writing any fixture (a post-write vm.skip leaks the fixture past the end-of-test clean).
    function _skipUnlessFfi() internal {
        // `jq --version` probes BOTH gates at once: ffi off reverts, and so does a missing jq.
        string[] memory probe = new string[](2);
        probe[0] = "jq";
        probe[1] = "--version";
        try this.runFfi(probe) {}
        catch {
            emit log_string("SKIP: ffi/jq unavailable (default profile has ffi off) - jq golden not run");
            vm.skip(true);
        }
    }

    /// @dev No-op re-write byte-identity (the shasum idiom, no `make`): recording the SAME entries a
    /// second time leaves the file byte-identical, so a fork that tracks `project/` gets zero git diff.
    function test_NoOpReWrite_ByteIdentical() public {
        RegistryWriter.recordDeterministic(SEL_NOOP, "token", "SYM_Token", TOKEN);
        RegistryWriter.recordDeterministic(SEL_NOOP, "tokenPool", "SYM_BurnMintTokenPool_2.0.0", POOL);
        bytes32 before = keccak256(bytes(vm.readFile(ProjectStore.path(SEL_NOOP))));

        // Identical re-record: same keys, same values.
        RegistryWriter.recordDeterministic(SEL_NOOP, "token", "SYM_Token", TOKEN);
        RegistryWriter.recordDeterministic(SEL_NOOP, "tokenPool", "SYM_BurnMintTokenPool_2.0.0", POOL);
        assertEq(
            keccak256(bytes(vm.readFile(ProjectStore.path(SEL_NOOP)))),
            before,
            "a no-op re-write mutated the file (must be byte-identical - zero git diff)"
        );
        ProjectScratch.clean(SEL_NOOP);
    }

    /// @dev Edge keys stay canonical: a mixed-case (EIP-55) hex value is emitted VERBATIM (not
    /// lowercased), a versioned deployment key containing dots is a single literal key, and the empty
    /// `lanes`/`roles` subtrees serialize as `{}`. The sorted order holds with multiple deployments.
    function test_EdgeKeys_MixedCaseHex_VersionedKey_EmptySubtrees() public {
        RegistryWriter.recordDeterministic(SEL_EDGE, "poolHooks", "SYM_BurnMint_PoolHooks", MIXED);
        RegistryWriter.recordDeterministic(SEL_EDGE, "token", "SYM_Token", TOKEN);
        string memory got = vm.readFile(ProjectStore.path(SEL_EDGE));

        // Mixed-case value emitted verbatim.
        assertEq(
            vm.parseJsonAddress(got, ".addresses.active.poolHooks"), MIXED, "mixed-case hex must round-trip verbatim"
        );
        assertTrue(
            _contains(got, "0xabCDeF0123456789AbcdEf0123456789aBCDEF01"), "checksummed value must not be lowercased"
        );
        // Versioned/dotted key readable as one literal key via bracket notation.
        assertEq(
            vm.parseJsonAddress(got, ".addresses.deployments[\"SYM_BurnMint_PoolHooks\"]"),
            MIXED,
            "dotted/underscored deployment key must be a single literal key"
        );
        // Empty subtrees + schema present.
        assertTrue(_contains(got, '"lanes": {}'), "empty lanes subtree must serialize as {}");
        assertTrue(_contains(got, '"roles": {}'), "empty roles subtree must serialize as {}");
        assertEq(vm.parseJsonUint(got, ".schema"), ProjectStore.SCHEMA, "schema 3 stamped");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "no trailing newline");
        ProjectScratch.clean(SEL_EDGE);
    }

    /// @dev The committed example ships in the exact canonical form: schema-3, no trailing newline, and
    /// resolvable by the real readers (`RegistryWriter.read*`), plus an ffi-gated jq byte-equality.
    function test_CommittedExample_IsCanonicalAndResolvable() public {
        string memory path = "project/ethereum-testnet-sepolia.example.json";
        string memory got = vm.readFile(path);
        assertEq(vm.parseJsonUint(got, ".schema"), ProjectStore.SCHEMA, "example schema is 3");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "committed example must have NO trailing newline");
        // Resolvable by the real readers: the reader keys on `project/<sel>.json`, so consume the example
        // by copying it verbatim to a scratch project file and reading THROUGH `RegistryWriter`.
        vm.writeFile(ProjectStore.path(SEL_EXAMPLE), got);
        assertEq(
            RegistryWriter.read(SEL_EXAMPLE, "tokenPool"),
            address(0x2222222222222222222222222222222222222222),
            "example active.tokenPool must resolve through the real reader"
        );
        assertEq(
            RegistryWriter.readDeployment(SEL_EXAMPLE, "BnM-T_BurnMintTokenPool_2.0.0"),
            address(0x2222222222222222222222222222222222222222),
            "example deployment entry must resolve through the real reader"
        );

        string[] memory full = new string[](6);
        full[0] = "jq";
        full[1] = "--indent";
        full[2] = "2";
        full[3] = "-S";
        full[4] = ".";
        full[5] = path;
        try this.runFfi(full) returns (bytes memory out) {
            assertEq(got, _trimTrailingNewline(string(out)), "committed example is not jq --indent 2 -S canonical");
        } catch {
            emit log_string("SKIP: ffi/jq unavailable - committed-example jq golden not run");
        }
        ProjectScratch.clean(SEL_EXAMPLE);
    }

    /// @dev The hand-authored `poolPolicy{}` block is canonical as documented: its keys sort into the
    /// top-level order (`addresses < lanes < poolPolicy < roles < schema`) and inside it
    /// (`blockDepth < waitForSafe` under `finality`, `ccvThreshold < finality`), so a correctly
    /// hand-edited file is a `jq --indent 2 -S` no-op (the `make fmt-config` repair path) and the
    /// writers' targeted subtree rewrites keep it byte-stable. ffi-gated like the other jq goldens.
    function test_PoolPolicy_HandAuthoredCanonical_FfiGated() public {
        _skipUnlessFfi();
        string memory doc = string.concat(
            "{\n",
            '  "addresses": {\n',
            '    "active": {},\n',
            '    "deployments": {}\n',
            "  },\n",
            '  "lanes": {},\n',
            '  "poolPolicy": {\n',
            '    "ccvThreshold": "1000000000000000000000",\n',
            '    "finality": {\n',
            '      "blockDepth": "5",\n',
            '      "waitForSafe": true\n',
            "    }\n",
            "  },\n",
            '  "roles": {},\n',
            '  "schema": 3\n',
            "}"
        );
        string memory path = ProjectStore.path(SEL_POLICY);
        vm.writeFile(path, doc);

        string[] memory full = new string[](6);
        full[0] = "jq";
        full[1] = "--indent";
        full[2] = "2";
        full[3] = "-S";
        full[4] = ".";
        full[5] = path;
        try this.runFfi(full) returns (bytes memory out) {
            assertEq(
                doc,
                _trimTrailingNewline(string(out)),
                "hand-authored poolPolicy block is not jq --indent 2 -S canonical"
            );
        } catch {
            emit log_string("SKIP: ffi/jq unavailable (default profile has ffi off) - jq golden not run");
            vm.skip(true);
        }
        ProjectScratch.clean(SEL_POLICY);
    }

    function _trimTrailingNewline(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0 && (b[n - 1] == 0x0a || b[n - 1] == 0x0d)) {
            n--;
        }
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
        return string(out);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory ndl = bytes(needle);
        if (ndl.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - ndl.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < ndl.length; j++) {
                if (h[i + j] != ndl[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
