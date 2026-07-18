// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ProjectStore} from "../../src/utils/ProjectStore.sol";

/// @title HelperConfigDivergenceNoticeTest — the env-override divergence notice (offline, byte-exact)
/// @notice An env override (`TOKEN` / `{CHAIN}_TOKEN` / …) wins over the project store and is READ-ONLY:
/// it is applied for the run but never written back, so a reviewed store can silently drift under an
/// incident override. `composeDivergenceNotice` is the side-effect-free text the broadcasting-only
/// `warnEnvOverride` prints for that case; being pure-ish it is BYTE-ASSERTABLE without any env/store
/// setup. This suite pins its FOUR states byte-exact — (a) env == store → ""; (b) env != store → the
/// full two-line NOTICE naming both values + the exact `make adopt-token` command; (c) env set + store
/// unset → the same NOTICE with "(unset)"; (d) no env override → "" — then proves `warnEnvOverride` is a
/// no-op under `forge test` (and that HelperConfig's constructor already ran it harmlessly for the acting
/// chain), and that resolving under an env override writes NOTHING back to the store (byte-identity).
contract HelperConfigDivergenceNoticeTest is Test {
    // Distinct, deterministic addresses: the env-resolved value vs the store's active pointer.
    address internal constant ENV_VAL = 0x00000000000000000000000000000000000000A1;
    address internal constant STORE_VAL = 0x00000000000000000000000000000000000000b2;

    // Fields the notice composes from (arbitrary — composeDivergenceNotice is a pure text builder).
    string internal constant SEL = "ethereum-testnet-sepolia";
    string internal constant ROLE = "token";
    string internal constant STEM = "TOKEN";

    // ── read-only byte-identity fixture: a uniquely-named scratch EVM chain + project store ──
    // Its chainNameIdentifier is unique, so the `{IDENT}_TOKEN` env override name is unique to this
    // test — never a shared name racing a parallel suite (the fake-env-seam discipline for env vars
    // HelperConfig reads directly). chainId/selector no other test uses.
    string internal constant BI_SEL = "zz-scratch-divnotice-readonly";
    string internal constant BI_IDENT = "ZZ_SCRATCH_DIVNOTICE";
    string internal constant BI_ENV = "ZZ_SCRATCH_DIVNOTICE_TOKEN";
    uint256 internal constant BI_CHAIN_ID = 889_300_001;
    uint64 internal constant BI_SELECTOR = 8_893_000_010_000_000_001;

    HelperConfig internal helper;

    function setUp() public {
        _clean();
        helper = new HelperConfig();
    }

    /// @dev Sweeps this suite's scratch fixtures from setUp(): the revert-safe guarantee (a failed
    /// test leaves its fixtures for inspection until the next run). Each test additionally removes
    /// ONLY the fixtures it owns at the end of its body (suite siblings run in parallel), so a green
    /// run leaves no residue.
    function _clean() private {
        string memory cfg = string.concat(vm.projectRoot(), "/config/chains/", BI_SEL, ".json");
        if (vm.exists(cfg)) vm.removeFile(cfg);
        string memory proj = ProjectStore.path(BI_SEL);
        if (vm.exists(proj)) vm.removeFile(proj);
    }

    /// @dev The expected two-line NOTICE, mirroring `composeDivergenceNotice` byte-for-byte. `storeVal`
    /// renders as "(unset)" when zero, else its hex — the only branch inside the builder.
    function _expectedNotice(address envVal, address storeVal) internal pure returns (string memory) {
        return string.concat(
            "NOTICE: ",
            ROLE,
            " resolved from env (",
            vm.toString(envVal),
            ") but project/",
            SEL,
            ".json addresses.active.",
            ROLE,
            " = ",
            storeVal == address(0) ? "(unset)" : vm.toString(storeVal),
            "\n        The override wins for this run and is NOT written back. If ",
            vm.toString(envVal),
            " is the new truth, reconcile the store: make adopt-token CHAIN=",
            SEL,
            " ",
            STEM,
            "=",
            vm.toString(envVal)
        );
    }

    // ------------------------------------------------------------ state (a): env == store → ""

    /// @dev Override matches the store: nothing has drifted, so the notice is empty.
    function test_ComposeNotice_EnvEqualsStore_Empty() public view {
        string memory notice = helper.composeDivergenceNotice(SEL, ROLE, STEM, ENV_VAL, ENV_VAL);
        assertEq(notice, "", "env == store must yield no notice");
    }

    // ------------------------------------------------------------ state (b): env != store → full NOTICE

    /// @dev Override differs from a POPULATED store: the full two-line notice naming both values and the
    /// composed `make adopt-token CHAIN=<sel> TOKEN=<envVal>` reconcile command, byte-exact.
    function test_ComposeNotice_EnvDiffersFromStore_FullNotice() public view {
        string memory notice = helper.composeDivergenceNotice(SEL, ROLE, STEM, ENV_VAL, STORE_VAL);
        assertEq(notice, _expectedNotice(ENV_VAL, STORE_VAL), "diverging override must compose the full notice");
    }

    // ------------------------------------------------------------ state (c): env set, store unset → "(unset)"

    /// @dev Override set but the store has NO active pointer (storeVal == 0): the notice renders the
    /// store side as "(unset)" and still emits the full reconcile command.
    function test_ComposeNotice_StoreUnset_ShowsUnset() public view {
        string memory notice = helper.composeDivergenceNotice(SEL, ROLE, STEM, ENV_VAL, address(0));
        assertEq(notice, _expectedNotice(ENV_VAL, address(0)), "an unset store must render (unset) in the notice");
        // And the "(unset)" token is actually present (guards against a future toString(0x0) regression).
        assertTrue(_contains(notice, " = (unset)"), "notice must carry the literal (unset) token");
    }

    // ------------------------------------------------------------ state (d): no env override → ""

    /// @dev No override at all (envVal == 0): there is nothing to reconcile, so the notice is empty even
    /// though the store is populated.
    function test_ComposeNotice_NoEnvOverride_Empty() public view {
        string memory notice = helper.composeDivergenceNotice(SEL, ROLE, STEM, address(0), STORE_VAL);
        assertEq(notice, "", "no env override (envVal 0) must yield no notice");
    }

    // ------------------------------------------------------------ warnEnvOverride: no-op under forge test

    /// @dev `warnEnvOverride` returns immediately under `forge test` (the `isContext(TestGroup)` guard)
    /// and for chainId 0. Calling it must not revert; the constructor already invoked it for the acting
    /// chain (block.chainid) with no effect (setUp's `new HelperConfig()` succeeded). We assert it is
    /// inert by proving a resolve is unaffected: composeDivergenceNotice on an equal pair is still "".
    function test_WarnEnvOverride_NoOpUnderForgeTest() public view {
        helper.warnEnvOverride(11_155_111); // a real chainId - still a no-op under forge test
        helper.warnEnvOverride(0); // the non-EVM/no-acting-chain early return
        assertEq(
            helper.composeDivergenceNotice(SEL, ROLE, STEM, ENV_VAL, ENV_VAL),
            "",
            "warnEnvOverride must have no effect on resolution under forge test"
        );
    }

    // ------------------------------------------------------------ read-only: no store write on resolve

    /// @dev The notice fires READ-ONLY: resolving a chain under an env override that DIVERGES from the
    /// store must not rewrite the store. We plant a scratch EVM chain whose store active.token = STORE_VAL,
    /// set the unique `{IDENT}_TOKEN` env override to ENV_VAL, construct a fresh HelperConfig (which
    /// resolves every configured chain, including this one, through the env rung), and assert the project
    /// file is BYTE-IDENTICAL afterwards. The override wins for resolution but the reviewed store is never
    /// touched - exactly the invariant the divergence notice exists to surface.
    function test_Resolve_UnderEnvOverride_LeavesStoreByteIdentical() public {
        _writeBiConfig();
        string memory storeJson = string.concat(
            "{\"addresses\":{\"active\":{\"token\":\"",
            vm.toString(STORE_VAL),
            "\"},\"deployments\":{}},\"lanes\":{},\"roles\":{},\"schema\":3}"
        );
        vm.writeFile(ProjectStore.path(BI_SEL), storeJson);
        bytes32 before = keccak256(bytes(vm.readFile(ProjectStore.path(BI_SEL))));

        vm.setEnv(BI_ENV, vm.toString(ENV_VAL)); // unique name - not a shared env var
        HelperConfig fresh = new HelperConfig();

        // The env override won for resolution (proves the divergence path ran), never the stored value...
        assertTrue(fresh.getDeployedToken(BI_CHAIN_ID) != STORE_VAL, "an env override must outrank the store");
        // ...and only when the chain-agnostic inline TOKEN alias is not ambiently set can we pin the
        // resolved value to OUR override exactly (TOKEN would outrank {IDENT}_TOKEN).
        if (vm.envOr("TOKEN", address(0)) == address(0)) {
            assertEq(fresh.getDeployedToken(BI_CHAIN_ID), ENV_VAL, "resolution must take the {IDENT}_TOKEN override");
        }
        // The core invariant: the store was NOT written back to match the override.
        assertEq(
            keccak256(bytes(vm.readFile(ProjectStore.path(BI_SEL)))),
            before,
            "resolving under an env override must leave the project store byte-identical (read-only)"
        );
        _clean();
    }

    /// @dev A discovery-safe EVM chain config (every key `ChainConfig.tryLoad` reads) with the UNIQUE
    /// chainNameIdentifier that makes the `{IDENT}_TOKEN` env override name test-local.
    function _writeBiConfig() internal {
        string memory json = string.concat(
            "{\"chainFamily\":\"evm\",\"name\":\"",
            BI_SEL,
            "\",\"displayName\":\"Scratch\",\"chainNameIdentifier\":\"",
            BI_IDENT,
            "\",\"environment\":\"testnet\",\"rpcEnv\":\"ZZ_SCRATCH_DIVNOTICE_RPC_URL\",",
            "\"explorerUrl\":\"https://example.invalid\",\"nativeCurrencySymbol\":\"ZZZ\",\"chainId\":\"",
            vm.toString(BI_CHAIN_ID),
            "\",\"chainSelector\":\"",
            vm.toString(BI_SELECTOR),
            "\",",
            "\"ccip\":{\"router\":\"0x0000000000000000000000000000000000000002\",",
            "\"rmnProxy\":\"0x0000000000000000000000000000000000000003\",",
            "\"tokenAdminRegistry\":\"0x0000000000000000000000000000000000000005\",",
            "\"registryModuleOwnerCustom\":\"0x0000000000000000000000000000000000000004\",",
            "\"link\":\"0x0000000000000000000000000000000000000001\",",
            "\"feeQuoter\":\"0x0000000000000000000000000000000000000006\",",
            "\"tokenPoolFactory\":\"0x0000000000000000000000000000000000000007\",\"feeTokens\":[]}}"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/config/chains/", BI_SEL, ".json"), json);
    }

    /// @dev Substring search (forge-std has no string.contains).
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
