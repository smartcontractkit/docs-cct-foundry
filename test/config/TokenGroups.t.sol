// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";
import {VerifyChain} from "../../script/config/VerifyChain.s.sol";

/// @dev External wrapper so `vm.expectRevert` observes the library's named group-validation revert (an
/// internal library revert is inlined into the test frame otherwise), and so the in-process `*In`
/// seam (`seedIfAbsentIn`/`requireSchemaIn`) and the env-reading `group()` are reachable from an
/// external call frame.
contract GroupHarness {
    function requireValidGroup(string memory g) external pure {
        ProjectStore.requireValidGroup(g);
    }

    function group() external view returns (string memory) {
        return ProjectStore.group();
    }

    function seedIfAbsentIn(string memory g, string memory name) external {
        ProjectStore.seedIfAbsentIn(g, name);
    }

    function requireSchemaIn(string memory g, string memory name) external view {
        ProjectStore.requireSchemaIn(g, name);
    }
}

/// @title TokenGroupsTest
/// @notice The in-process half of the token-group coverage. `PROJECT_GROUP` (the `GROUP=` make var)
/// moves a chain's project file to `project/<group>/<selectorName>.json`, its own mesh universe; unset
/// is the flat default `project/<selectorName>.json`, BYTE-IDENTICAL to a single-token (flat) clone.
///
/// @dev **Seam rule.** Forge runs suites in parallel and `vm.setEnv` is process-global, so these tests
/// NEVER set `PROJECT_GROUP`; they exercise the group through the explicit `*In(group, ...)` variants
/// (`relIn`/`pathIn`/`displayIn`/`seedIfAbsentIn`/`requireSchemaIn`) and the `requireValidGroup` pure
/// validator. The env-driven `group()` (real `PROJECT_GROUP=g forge` / `make GROUP=g`) is exercised by
/// the SHELL tier (`script/config/test-tooling.sh`) and the live session, where a subprocess owns its
/// own env. Every test owns a distinct `zz-scratch-*` selectorName and, when it seeds a group, a
/// distinct `zz-scratch-*` group DIRECTORY (`project/zz-scratch-*/`, gitignored), both cleaned in
/// `setUp()` (revert-safe, never at end-of-test).
contract TokenGroupsTest is Test {
    GroupHarness internal harness;

    // Distinct scratch selectorNames + group directories, one per concern (parallel-safe basenames).
    string internal constant SEL_FLAT = "zz-scratch-groups-flat";
    string internal constant SEL_CLOBBER = "zz-scratch-groups-clobber";
    string internal constant SEL_SEED = "zz-scratch-groups-seed";
    string internal constant SEL_NOSEED = "zz-scratch-groups-noseed";
    string internal constant SEL_SMEAR = "zz-scratch-groups-smear";
    string internal constant SEL_NOTICE = "zz-scratch-groups-notice";

    string internal constant GRP_A = "zz-scratch-groups-ga";
    string internal constant GRP_B = "zz-scratch-groups-gb";
    string internal constant GRP_SEED = "zz-scratch-groups-gseed";
    string internal constant GRP_SMEAR = "zz-scratch-groups-gsmear";
    string internal constant GRP_NOSEED = "zz-scratch-groups-gnoseed";
    // A VISIBLE test group (zz-tt-*, not zz-scratch-*): the group-sweeping tools do NOT skip it, so the
    // doctor's grouped-sibling detection can be asserted on it.
    string internal constant GRP_NOTICE = "zz-tt-groups-notice";

    /// @dev The canonical (2-space, sorted, no trailing newline) empty skeleton `seedIfAbsentIn` writes —
    /// the exact bytes `vm.writeJson(SKELETON, path)` emits, pinned so a grouped seed is proven identical
    /// to a flat one. Mirrors the golden in ProjectCanonical.t.sol on a GROUPED path.
    string internal constant CANON_SKELETON = "{\n" '  "addresses": {\n' '    "active": {},\n' '    "deployments": {}\n'
        "  },\n" '  "lanes": {},\n' '  "roles": {},\n' '  "schema": 3\n' "}";

    function setUp() public {
        harness = new GroupHarness();
        ProjectScratch.clean(SEL_FLAT);
        ProjectScratch.clean(SEL_CLOBBER);
        ProjectScratch.clean(SEL_SEED);
        ProjectScratch.clean(SEL_NOSEED);
        ProjectScratch.clean(SEL_SMEAR);
        ProjectScratch.clean(SEL_NOTICE);
        ProjectScratch.cleanGroupDir(GRP_A);
        ProjectScratch.cleanGroupDir(GRP_B);
        ProjectScratch.cleanGroupDir(GRP_SEED);
        ProjectScratch.cleanGroupDir(GRP_SMEAR);
        ProjectScratch.cleanGroupDir(GRP_NOSEED);
        ProjectScratch.cleanGroupDir(GRP_NOTICE);
    }

    // ---------------------------------------------------------------- (1) flat-default byte-equivalence

    /// @dev The flat default (`group == ""`) composes the plain `project/<selectorName>.json` path: no
    /// `<group>/` segment. `path`/`display` (env-driven) resolve to the flat forms too, because `group()`
    /// reads an unset `PROJECT_GROUP` in the forge-test context.
    function test_FlatDefault_ByteEquivalentToFlatLayout() public view {
        assertEq(
            ProjectStore.relIn("", SEL_FLAT),
            string.concat("project/", SEL_FLAT, ".json"),
            "flat rel has no group segment"
        );
        assertEq(ProjectStore.displayIn("", SEL_FLAT), string.concat("project/", SEL_FLAT, ".json"), "flat display");
        assertEq(
            ProjectStore.pathIn("", SEL_FLAT),
            string.concat(vm.projectRoot(), "/project/", SEL_FLAT, ".json"),
            "flat abs path"
        );
        // The env-driven accessors resolve to the flat forms in the forge-test context (PROJECT_GROUP unset).
        assertEq(
            ProjectStore.path(SEL_FLAT), ProjectStore.pathIn("", SEL_FLAT), "path() == flat pathIn in test context"
        );
        assertEq(ProjectStore.display(SEL_FLAT), ProjectStore.displayIn("", SEL_FLAT), "display() == flat displayIn");
    }

    /// @dev A non-empty group inserts exactly one `<group>/` segment at every composer.
    function test_GroupedForms_InsertOneGroupSegment() public view {
        assertEq(ProjectStore.relIn("usdx", SEL_FLAT), string.concat("project/usdx/", SEL_FLAT, ".json"), "grouped rel");
        assertEq(
            ProjectStore.displayIn("usdx", SEL_FLAT),
            string.concat("project/usdx/", SEL_FLAT, ".json"),
            "grouped display"
        );
        assertEq(
            ProjectStore.pathIn("usdx", SEL_FLAT),
            string.concat(vm.projectRoot(), "/project/usdx/", SEL_FLAT, ".json"),
            "grouped abs path"
        );
    }

    // ---------------------------------------------------------------- (5) group-name validation

    /// @dev Every invalid group name reverts with the SINGLE named error (never a raw cheatcode revert),
    /// covering the traversal-adjacent shapes `.`/`/`/`..` and the alphabet/first-char rules.
    function test_RequireValidGroup_Negatives_NamedRevert() public {
        _expectBadGroup("Bad"); // uppercase
        _expectBadGroup("a/b"); // slash (path traversal)
        _expectBadGroup(".."); // parent dir
        _expectBadGroup("."); // single dot (current dir)
        _expectBadGroup("a b"); // space
        _expectBadGroup("-x"); // leading hyphen
        _expectBadGroup("A"); // single uppercase
        _expectBadGroup("a_b"); // underscore is not in [a-z0-9-]
    }

    /// @dev `default` is a valid-shaped name but reserved (it labels the flat/unnamed group), rejected
    /// with its own named error.
    function test_RequireValidGroup_DefaultReserved() public {
        vm.expectRevert(
            bytes("[project] PROJECT_GROUP 'default' is reserved for the flat (unnamed) group - choose another name")
        );
        harness.requireValidGroup("default");
    }

    /// @dev The write seam validates too: `seedIfAbsentIn` with a traversal group reverts (the group flows
    /// through `pathIn`->`relIn`->`requireValidGroup` before any `createDir`/`writeJson`), so no direct
    /// `*In(userInput, ...)` caller can escape `project/`.
    function test_SeedIfAbsentIn_TraversalGroup_Reverts() public {
        vm.expectRevert(
            bytes(
                "[project] PROJECT_GROUP '..' is not a valid token-group name - use [a-z0-9][a-z0-9-]* (lowercase letters, digits, and hyphens; first character not a hyphen)"
            )
        );
        harness.seedIfAbsentIn("..", SEL_NOSEED);
    }

    /// @dev Valid names (and the empty flat default) pass and compose the expected rel path.
    function test_RequireValidGroup_Positives_ComposeCorrectly() public view {
        string[4] memory ok = ["", "usdx", "a-b-1", "x0"];
        for (uint256 i = 0; i < ok.length; i++) {
            harness.requireValidGroup(ok[i]); // must not revert
        }
        assertEq(ProjectStore.relIn("usdx", "c"), "project/usdx/c.json", "usdx composes");
        assertEq(ProjectStore.relIn("a-b-1", "c"), "project/a-b-1/c.json", "a-b-1 composes");
        assertEq(ProjectStore.relIn("x0", "c"), "project/x0/c.json", "x0 composes");
        assertEq(ProjectStore.relIn("", "c"), "project/c.json", "empty stays flat");
    }

    // ---------------------------------------------------------------- (2) cross-group clobber isolation

    /// @dev The SAME selectorName in two groups resolves to two DISTINCT files under `project/<group>/`;
    /// seeding both leaves byte-identical skeletons, and a subtree write into group A never touches group
    /// B (the whole point of the segment — separate mesh universes). Driven through the `*In` seam only
    /// (no env), which is exactly how a parallel-safe test reaches a specific group.
    function test_CrossGroupClobberIsolation_ViaInSeam() public {
        harness.seedIfAbsentIn(GRP_A, SEL_CLOBBER);
        harness.seedIfAbsentIn(GRP_B, SEL_CLOBBER);

        string memory pathA = ProjectStore.pathIn(GRP_A, SEL_CLOBBER);
        string memory pathB = ProjectStore.pathIn(GRP_B, SEL_CLOBBER);
        assertTrue(keccak256(bytes(pathA)) != keccak256(bytes(pathB)), "same chain in two groups -> distinct files");
        assertTrue(vm.exists(pathA) && vm.exists(pathB), "both grouped files seeded");
        // Fresh seeds are byte-identical (both the canonical empty skeleton).
        assertEq(
            keccak256(bytes(vm.readFile(pathA))), keccak256(bytes(vm.readFile(pathB))), "fresh seeds are byte-identical"
        );

        bytes32 bBefore = keccak256(bytes(vm.readFile(pathB)));
        // Subtree write into A ONLY (targeted `.addresses`, never a whole-file write) — the same write
        // shape the registry uses; here it is aimed at the grouped path via the seam.
        vm.writeJson(
            "{\"active\":{\"token\":\"0x1111111111111111111111111111111111111111\"},\"deployments\":{}}",
            pathA,
            ".addresses"
        );

        assertTrue(keccak256(bytes(vm.readFile(pathA))) != bBefore, "group A mutated");
        assertEq(keccak256(bytes(vm.readFile(pathB))), bBefore, "group B byte-identical after writing group A");
    }

    // ---------------------------------------------------------------- (E) canonical golden in a group dir

    /// @dev `seedIfAbsentIn` creates the `project/<group>/` directory and writes the canonical empty
    /// skeleton — byte-identical to the flat seed (2-space, sorted, NO trailing newline). Pins the golden
    /// on a GROUPED path and cross-checks against `jq --indent 2 -S` when ffi is available.
    function test_SeedIfAbsentIn_CreatesGroupDir_CanonicalSkeleton() public {
        string memory p = ProjectStore.pathIn(GRP_SEED, SEL_SEED);
        assertFalse(vm.exists(p), "precondition: grouped file absent");
        harness.seedIfAbsentIn(GRP_SEED, SEL_SEED);

        assertTrue(vm.exists(p), "grouped file created (dir auto-created)");
        string memory got = vm.readFile(p);
        assertEq(got, CANON_SKELETON, "grouped seed is the canonical skeleton (byte-identical to flat)");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "grouped project file has NO trailing newline");
        // The schema rung accepts its own freshly-seeded group file.
        harness.requireSchemaIn(GRP_SEED, SEL_SEED);

        // ffi-gated cross-check against jq --indent 2 -S (default profile has ffi off -> SKIP, not fail).
        string[] memory cmd = new string[](6);
        cmd[0] = "jq";
        cmd[1] = "--indent";
        cmd[2] = "2";
        cmd[3] = "-S";
        cmd[4] = ".";
        cmd[5] = p;
        try this.runFfi(cmd) returns (bytes memory out) {
            assertEq(got, _trimTrailingNewline(string(out)), "grouped seed != jq --indent 2 -S canonical");
        } catch {
            emit log_string("SKIP: ffi/jq unavailable (default profile has ffi off) - grouped jq golden not run");
            vm.skip(true);
        }
    }

    // ---------------------------------------------------------------- (D) read-path safety / no env smear

    /// @dev A READ-path schema check for a group whose file is ABSENT is a clean no-op — it must NOT
    /// silently seed a file (the read paths never write). `requireSchemaIn` returns without creating
    /// `project/<group>/<sel>.json` (nor the directory).
    function test_RequireSchemaIn_AbsentFile_NoSilentSeed() public view {
        // Own group dir (never created by another test) so the directory assertion cannot flake.
        string memory p = ProjectStore.pathIn(GRP_NOSEED, SEL_NOSEED);
        string memory dir = string.concat(vm.projectRoot(), "/project/", GRP_NOSEED);
        harness.requireSchemaIn(GRP_NOSEED, SEL_NOSEED); // must not revert, must not write
        assertFalse(vm.exists(p), "read-path schema check must NOT seed a file");
        assertFalse(vm.exists(dir), "read-path schema check must NOT create the group directory");
    }

    /// @dev No group-env smear: under `forge test` no suite ever sets `PROJECT_GROUP`, so `group()` reads
    /// unset and returns "" — even in the same run where other tests drive specific groups through the
    /// `*In` seam. This is the invariant that makes the seam parallel-safe.
    function test_ForgeTestContext_GroupIsEmpty_NoEnvSmear() public {
        // Exercise a grouped seam write first, then prove group() is still the flat default.
        harness.seedIfAbsentIn(GRP_SMEAR, SEL_SMEAR);
        assertEq(harness.group(), "", "group() must be the flat default in the forge-test context (no env smear)");
        assertEq(ProjectStore.path(SEL_SMEAR), ProjectStore.pathIn("", SEL_SMEAR), "env-driven path stays flat");
    }

    // ---------------------------------------------------------------- (E) divergence-notice format

    /// @dev The env-override divergence notice names the project file (`ProjectStore.display`) and the
    /// `make adopt-token` reconcile command; it is side-effect free and byte-assertable. In the
    /// forge-test context `display` resolves the FLAT path (no env group); the GROUPED-path form
    /// (`project/<group>/<name>.json`) is pinned by the live/shell tier where a real `PROJECT_GROUP` is
    /// set. Here we pin the format and that it carries the resolved project path + reconcile command.
    function test_ComposeDivergenceNotice_NamesProjectFileAndReconcile() public {
        HelperConfig hc = new HelperConfig();
        address envVal = address(0xAAaA000000000000000000000000000000000001);
        address storeVal = address(0xBbbb000000000000000000000000000000000002);
        string memory notice = hc.composeDivergenceNotice(SEL_FLAT, "token", "TOKEN", envVal, storeVal);

        assertTrue(_contains(notice, "NOTICE: token resolved from env"), "notice header");
        assertTrue(
            _contains(notice, string.concat("project/", SEL_FLAT, ".json")), "notice names the (flat) project file"
        );
        assertTrue(_contains(notice, "make adopt-token CHAIN="), "notice names the reconcile command");
        // Silent when there is no override or the override matches the store.
        assertEq(
            hc.composeDivergenceNotice(SEL_FLAT, "token", "TOKEN", address(0), storeVal), "", "no override -> silent"
        );
        assertEq(
            hc.composeDivergenceNotice(SEL_FLAT, "token", "TOKEN", storeVal, storeVal),
            "",
            "matching override -> silent"
        );
    }

    // ---------------------------------------------------------------- (doctor) grouped-sibling notice

    /// @dev The ungrouped doctor lists token groups that also hold the chain, so a routine no-`GROUP`
    /// check does not silently skip a grouped token. `groupedSiblingsForTest` names the group when
    /// `project/<group>/<name>.json` exists, and yields "" when none do (the one-token user sees no
    /// notice). Detection only; the console line and its `forge test` suppression are covered by the
    /// live/shell tier where a real doctor runs.
    function test_DoctorNoticesGroupedSiblings() public {
        VerifyChain doctor = new VerifyChain();
        assertEq(doctor.groupedSiblingsForTest(SEL_NOTICE), "", "no grouped sibling -> no notice (flat/one-token case)");
        // A zz-scratch-* group is INVISIBLE to the sweep (leaked-scratch class) -> still no notice.
        harness.seedIfAbsentIn(GRP_A, SEL_NOTICE);
        assertEq(doctor.groupedSiblingsForTest(SEL_NOTICE), "", "scratch group dir must not surface in the notice");
        // A real (non-scratch) group holding the chain IS reported.
        harness.seedIfAbsentIn(GRP_NOTICE, SEL_NOTICE);
        assertEq(doctor.groupedSiblingsForTest(SEL_NOTICE), GRP_NOTICE, "notice names the group holding the chain");
    }

    // ---------------------------------------------------------------- helpers

    function _expectBadGroup(string memory g) internal {
        vm.expectRevert(
            bytes(
                string.concat(
                    "[project] PROJECT_GROUP '",
                    g,
                    "' is not a valid token-group name - use [a-z0-9][a-z0-9-]* (lowercase letters, digits, and hyphens; first character not a hyphen)"
                )
            )
        );
        harness.requireValidGroup(g);
    }

    /// @dev External wrapper so the ffi call can be `try`-caught (an internal ffi revert is not catchable).
    function runFfi(string[] calldata cmd) external returns (bytes memory) {
        return vm.ffi(cmd);
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
