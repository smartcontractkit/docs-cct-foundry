// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeploymentUtils} from "../../script/utils/DeploymentUtils.s.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @dev Minimal token exposing `symbol()` so the pool/lock-box ledger path (which resolves the file's
/// symbol prefix via `DeploymentUtils._getSymbol`'s on-chain `symbol()` call) has a real contract to
/// read - foundry reverts on a call to a non-contract address, so a bare EOA cannot stand in.
contract MockSymbolToken {
    string public symbol = "BnM-T";
}

/// @title HistoryLedgerTest - the `history/` per-artifact deploy ledger
/// @notice `DeploymentUtils.save*` writes an append-only ledger under `history/<category>/<selectorName>/`,
/// one timestamped JSON file per deployed artifact whose body is `vm.writeJson` of the serialized
/// address(es) keyed by `chainNameIdentifier`. This suite pins four invariants, all offline:
///   1. **Byte-for-byte golden** of the token artifact body, with an **INJECTABLE CLOCK** (`vm.warp` to
///      a fixed timestamp - never the ambient `block.timestamp`) so the golden and the filename are stable.
///   2. **selectorName dir keying incl. svm**: the directory is keyed by the canonical selectorName, so a
///      chainId-0 (svm) chain resolves to `history/<cat>/<selectorName>/` and NEVER a `history/<cat>/0/` dir.
///   3. **Append-only**: a second deploy-record writes a NEW timestamped file and leaves the first file
///      BYTE-IDENTICAL (pure create, never rewrite).
///   4. The body carries NO timestamp (it is the address(es) only), so the golden is a content pin
///      independent of the clock.
///
/// `DeploymentUtils` reads `block.timestamp` for the filename; `vm.warp` is the seam a forge test uses to
/// make that filename deterministic.
contract HistoryLedgerTest is Test {
    // Unique per-test scratch selectorNames (the ledger dir key). EVM + one svm (chainId-0) key.
    string internal constant SEL_GOLDEN = "zz-scratch-hist-golden";
    string internal constant SEL_SVM = "zz-scratch-hist-svm";
    string internal constant SEL_APPEND = "zz-scratch-hist-append";
    string internal constant SEL_POOL = "zz-scratch-hist-pool";

    // Fixed injected clock values (seam = vm.warp, NOT ambient block.timestamp).
    uint256 internal constant T1 = 1_700_000_000;
    uint256 internal constant T2 = 1_700_000_042;

    address internal constant TOKEN = address(0x1111111111111111111111111111111111111111);
    address internal constant POOL = address(0x2222222222222222222222222222222222222222);
    string internal constant CNI = "ETHEREUM_SEPOLIA";

    function setUp() public {
        _clean();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string[4] memory sels = [SEL_GOLDEN, SEL_SVM, SEL_APPEND, SEL_POOL];
        for (uint256 i = 0; i < sels.length; i++) {
            ProjectScratch.cleanHistory(sels[i]);
        }
    }

    function _tokensDir(string memory sel) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/history/tokens/", sel, "/");
    }

    // ------------------------------------------------------------ (1) byte-for-byte golden + clock seam

    /// @dev The token artifact body is `vm.writeJson` of a single serialized
    /// address keyed `<chainNameIdentifier>_TOKEN`, 2-space indent, NO trailing newline. Pinned as a
    /// literal so any serialization change (spacing, key, a stray newline) is a hard failure. The clock
    /// is INJECTED via `vm.warp(T1)` so the filename is `<T1>-<symbol>-Token.json` deterministically.
    function test_TokenArtifact_ByteForByteGolden_InjectedClock() public {
        vm.warp(T1);
        DeploymentUtils._saveTokenDeployment(vm, SEL_GOLDEN, CNI, "BnM-T", TOKEN);

        string memory file = string.concat(_tokensDir(SEL_GOLDEN), vm.toString(T1), "-BnM-T-Token.json");
        assertTrue(vm.exists(file), "ledger file must be named <injected-timestamp>-<symbol>-Token.json");

        string memory got = vm.readFile(file);
        string memory expected =
            string.concat("{\n", '  "', CNI, '_TOKEN": "0x1111111111111111111111111111111111111111"\n', "}");
        assertEq(got, expected, "token ledger body is not the expected byte-for-byte shape");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "ledger body must have NO trailing newline");
        // The body carries the address only - NO timestamp leaks into content (clock is filename-only).
        assertFalse(_contains(got, vm.toString(T1)), "the timestamp must NOT appear in the body (filename-only)");
        ProjectScratch.cleanHistory(SEL_GOLDEN);
    }

    /// @dev The two-address token-pool artifact: both `<CNI>_TOKEN_POOL` and `<CNI>_TOKEN` keys resolve;
    /// filename carries the injected clock. Structural (not byte) pin, so serialization key-ordering is
    /// not a spurious failure while the format (both keys, no trailing newline) is still asserted.
    function test_TokenPoolArtifact_BothKeys_InjectedClock() public {
        vm.warp(T1);
        address token = address(new MockSymbolToken());
        DeploymentUtils._saveTokenPoolDeployment(vm, SEL_POOL, CNI, POOL, token, "BurnMint");

        string memory dir = string.concat(vm.projectRoot(), "/history/token-pools/", SEL_POOL, "/");
        string memory file = string.concat(dir, vm.toString(T1), "-BnM-T-BurnMintTokenPool.json");
        assertTrue(
            vm.exists(file), "pool ledger file must be named <injected-timestamp>-<symbol>-BurnMintTokenPool.json"
        );
        string memory got = vm.readFile(file);
        assertEq(vm.parseJsonAddress(got, string.concat(".", CNI, "_TOKEN_POOL")), POOL, "pool key resolves");
        assertEq(vm.parseJsonAddress(got, string.concat(".", CNI, "_TOKEN")), token, "token key resolves");
        assertTrue(bytes(got)[bytes(got).length - 1] != 0x0a, "pool ledger body must have NO trailing newline");
        ProjectScratch.cleanHistory(SEL_POOL);
    }

    // ------------------------------------------------------------ (2) selectorName keying, no 0/ dir

    /// @dev The ledger directory is keyed by the canonical **selectorName**, never the chainId. An svm
    /// chain reports chainId "0", yet the ledger keys by selectorName, so it resolves to
    /// `history/tokens/<svm-selectorName>/` and NO `0/` dir under ANY category is ever created.
    function test_SvmSelectorNameKeying_NoZeroDir() public {
        vm.warp(T1);
        // A chainId-0 svm chain is keyed purely by its selectorName in the ledger path.
        DeploymentUtils._saveTokenDeployment(vm, SEL_SVM, "SOLANA_DEVNET", "BnM-T", TOKEN);

        assertTrue(
            vm.exists(string.concat(_tokensDir(SEL_SVM), vm.toString(T1), "-BnM-T-Token.json")),
            "svm dir keyed by selectorName"
        );
        // NO chainId-0 directory under any history category.
        string[4] memory categories = ["tokens", "token-pools", "lock-boxes", "advanced-pool-hooks"];
        for (uint256 i = 0; i < categories.length; i++) {
            assertFalse(
                vm.exists(string.concat(vm.projectRoot(), "/history/", categories[i], "/0")),
                string.concat("history/", categories[i], "/0/ must NEVER be created (dirs key by selectorName)")
            );
        }
        ProjectScratch.cleanHistory(SEL_SVM);
    }

    // ------------------------------------------------------------ (3) append-only

    /// @dev Append-only: a SECOND deploy-record (later injected clock) writes a NEW timestamped file and
    /// leaves the FIRST file BYTE-IDENTICAL - pure create, never rewrite. Two distinct files result.
    function test_AppendOnly_SecondDeploy_NewFile_FirstByteIdentical() public {
        vm.warp(T1);
        DeploymentUtils._saveTokenDeployment(vm, SEL_APPEND, CNI, "BnM-T", TOKEN);
        string memory file1 = string.concat(_tokensDir(SEL_APPEND), vm.toString(T1), "-BnM-T-Token.json");
        bytes32 file1Before = keccak256(bytes(vm.readFile(file1)));

        // A second deploy at a later injected time - a redeploy of the same artifact.
        vm.warp(T2);
        DeploymentUtils._saveTokenDeployment(vm, SEL_APPEND, CNI, "BnM-T", POOL);
        string memory file2 = string.concat(_tokensDir(SEL_APPEND), vm.toString(T2), "-BnM-T-Token.json");

        assertTrue(vm.exists(file1), "first ledger file must survive the second deploy (append-only)");
        assertTrue(vm.exists(file2), "second deploy must write a NEW timestamped file");
        assertTrue(keccak256(bytes(file1)) != keccak256(bytes(file2)), "the two ledger files must be distinct");
        assertEq(
            keccak256(bytes(vm.readFile(file1))),
            file1Before,
            "the first ledger file must be BYTE-IDENTICAL (never rewritten)"
        );
        // Exactly two files in the directory (no in-place overwrite).
        assertEq(
            vm.readDir(string.concat(vm.projectRoot(), "/history/tokens/", SEL_APPEND)).length,
            2,
            "exactly two append-only files"
        );
        ProjectScratch.cleanHistory(SEL_APPEND);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
