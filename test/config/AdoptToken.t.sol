// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {AdoptToken} from "../../script/config/AdoptToken.s.sol";
import {PoolVersion} from "../../script/utils/PoolVersion.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";

/// @dev A minimal adoptable pool: configurable typeAndVersion and a getToken pointing at a real token.
contract MockAdoptablePool {
    string public typeAndVersion;
    address internal immutable i_token;

    constructor(string memory t, address token) {
        typeAndVersion = t;
        i_token = token;
    }

    function getToken() external view returns (address) {
        return i_token;
    }
}

/// @dev A dev-stamped adoptable pool for the POOL_VERSION_OVERRIDE test. Storage-free (the string
///      is hardcoded, the token is an immutable baked into the runtime code) so the code can be
///      `vm.etch`ed to a dedicated address: vm.setEnv is process-wide and suites run in parallel,
///      so the override entry must target an address no other test can ever resolve.
contract MockAdoptableDevPool {
    address internal immutable i_token;

    constructor(address token) {
        i_token = token;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "BurnMintTokenPool 1.6.x-dev";
    }

    function getToken() external view returns (address) {
        return i_token;
    }

    function getCurrentOutboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}

    function getCurrentInboundRateLimiterState(uint64) external pure returns (RateLimiter.TokenBucket memory b) {}
}

/// @notice Adoption proofs against LIVE externally deployed contracts on a Sepolia fork. The
///         fixture addresses below were deployed by a DIFFERENT project (not this repo's scripts),
///         which is the exact scenario adoption exists for: a token/pool this repo has never seen
///         must validate and then resolve like its own deployments.
///         Registry writes are tested against a synthetic chain id with setUp cleanup, so the
///         repo's real `addresses/` files are never touched by the suite.
contract AdoptTokenForkTest is Test {
    // Externally deployed Sepolia fixtures (source-verified; see the deploying project's ledger).
    address internal constant PLAIN_OWNABLE_TOKEN = 0x6D4ebE2488A8E2792c4b16CB7a4f6D9C08C46998; // owner() only
    address internal constant CCT_TOKEN = 0x65901d3177F69CFA5b341C95D3943e72FFb2716A; // getCCIPAdmin()
    address internal constant CCT_POOL_200 = 0x3C5Cafc14751b12CE7ad1Af669cF81586CD5061E; // BurnMintTokenPool 2.0.0
    address internal constant MATRIX_TOKEN = 0x10399C551d63F596B9b980E089d7ad5B616Fc152; // PMTK
    address internal constant POOL_150 = 0x12308B9b64CA40BD8d15daB6679876123Afda026; // BurnMintTokenPool 1.5.0
    address internal constant DEV_STAMPED_POOL = 0xCb8eF49c81aCf4E3100B164516f5051694cD5e31; // LockReleaseTokenPool 1.6.x-dev

    uint256 internal constant SYNTHETIC_CHAIN_ID = 91_500_042;

    AdoptToken internal script;
    string internal sepoliaJson;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length > 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");
        }
        script = new AdoptToken();
        sepoliaJson = vm.readFile("config/chains/ethereum-testnet-sepolia.json");

        // Registry hygiene: the synthetic chain file must not exist when a test starts.
        string memory path = string.concat(vm.projectRoot(), "/addresses/", vm.toString(SYNTHETIC_CHAIN_ID), ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Validation against live externally deployed contracts
    // ─────────────────────────────────────────────────────────────────────────

    function test_Validate_PlainOwnableToken_NoPool() public {
        AdoptToken.AdoptPlan memory plan =
            script.validateAdoption(sepoliaJson, block.chainid, PLAIN_OWNABLE_TOKEN, address(0));
        assertEq(plan.token, PLAIN_OWNABLE_TOKEN, "token");
        assertEq(plan.adminPath, "owner()", "plain Ownable token must resolve the owner() path");
        assertEq(bytes(plan.poolTypeAndVersion).length, 0, "no pool adopted");
    }

    function test_Validate_CctTokenWithPool() public {
        AdoptToken.AdoptPlan memory plan = script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, CCT_POOL_200);
        assertEq(plan.adminPath, "getCCIPAdmin()", "CCT token must resolve the getCCIPAdmin() path");
        assertEq(plan.poolTypeAndVersion, "BurnMintTokenPool 2.0.0", "pool type and version");
    }

    function test_Validate_V150Pool() public {
        AdoptToken.AdoptPlan memory plan = script.validateAdoption(sepoliaJson, block.chainid, MATRIX_TOKEN, POOL_150);
        assertEq(plan.poolTypeAndVersion, "BurnMintTokenPool 1.5.0", "1.5.0 pool adopts");
    }

    function test_Validate_RejectsMismatchedPair() public {
        // CCT_POOL_200 manages CCT_TOKEN, not the plain Ownable token.
        vm.expectRevert(
            bytes(
                string.concat(
                    "pool/token mismatch: pool ",
                    vm.toString(CCT_POOL_200),
                    " manages ",
                    vm.toString(CCT_TOKEN),
                    ", not ",
                    vm.toString(PLAIN_OWNABLE_TOKEN)
                )
            )
        );
        script.validateAdoption(sepoliaJson, block.chainid, PLAIN_OWNABLE_TOKEN, CCT_POOL_200);
    }

    function test_Validate_RejectsDevStampedPool() public {
        try script.validateAdoption(sepoliaJson, block.chainid, MATRIX_TOKEN, DEV_STAMPED_POOL) {
            revert("dev-stamped pool unexpectedly adopted");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "DevBuildRefused"), reason);
            assertTrue(_contains(reason, "LockReleaseTokenPool 1.6.x-dev"), reason);
            assertTrue(_contains(reason, "POOL_VERSION_OVERRIDE"), reason);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Version-catalog gating (mock pools wrapping the live CCT token)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Every cataloged version adopts; the recorded string is the full on-chain one.
    function test_Validate_AllCatalogedVersionsAdopt() public {
        string[4] memory versions = ["1.5.0", "1.5.1", "1.6.1", "2.0.0"];
        for (uint256 i = 0; i < versions.length; i++) {
            string memory t = string.concat("BurnMintTokenPool ", versions[i]);
            address pool = address(new MockAdoptablePool(t, CCT_TOKEN));
            AdoptToken.AdoptPlan memory plan = script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, pool);
            assertEq(plan.poolTypeAndVersion, t, string.concat("cataloged version must adopt: ", versions[i]));
        }
    }

    function test_Validate_RejectsUnknownVersion() public {
        address pool = address(new MockAdoptablePool("BurnMintTokenPool 1.6.0", CCT_TOKEN));
        try script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, pool) {
            revert("unknown-version pool unexpectedly adopted");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "UnsupportedPoolVersion"), reason);
            assertTrue(_contains(reason, "1.5.0, 1.5.1, 1.6.1, 2.0.0"), reason);
        }
    }

    function test_Validate_RejectsForeignPoolType() public {
        // A specialized pool versions independently; its 1.5.1 is not TokenPool 1.5.1.
        address pool = address(new MockAdoptablePool("USDCTokenPool 1.5.1", CCT_TOKEN));
        try script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, pool) {
            revert("foreign-type pool unexpectedly adopted");
        } catch Error(string memory reason) {
            assertTrue(_contains(reason, "UnsupportedPoolType"), reason);
            assertTrue(_contains(reason, "USDCTokenPool"), reason);
        }
    }

    /// @dev POOL_VERSION_OVERRIDE lets an operator adopt a dev-stamped pool after asserting its ABI;
    ///      the plan (and therefore the registry) still records the TRUE on-chain string.
    function test_Validate_OverrideAdmitsDevPool_RecordsTrueString() public {
        // Etched at a dedicated address: the env entry is address-scoped, so even while it is set
        // (vm.setEnv is process-wide) no parallel test can resolve this address.
        address pool = address(uint160(uint256(keccak256("adopt-token-pool-version-override-test"))));
        vm.etch(pool, address(new MockAdoptableDevPool(CCT_TOKEN)).code);
        vm.setEnv(PoolVersion.OVERRIDE_ENV, string.concat(vm.toString(pool), "=1.6.1"));

        AdoptToken.AdoptPlan memory plan = script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, pool);

        vm.setEnv(PoolVersion.OVERRIDE_ENV, "");
        assertEq(plan.poolTypeAndVersion, "BurnMintTokenPool 1.6.x-dev", "registry keying uses the TRUE string");
    }

    function _contains(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        if (n.length > b.length) return false;
        for (uint256 i = 0; i + n.length <= b.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (b[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function test_Validate_RejectsNonContractToken() public {
        vm.expectRevert(bytes(string.concat("no contract code at token ", vm.toString(address(0xdead)))));
        script.validateAdoption(sepoliaJson, block.chainid, address(0xdead), address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Registry write (synthetic chain id; real addresses/ files untouched)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Record_WritesBothStores() public {
        AdoptToken.AdoptPlan memory plan = script.validateAdoption(sepoliaJson, block.chainid, CCT_TOKEN, CCT_POOL_200);
        plan.chainId = SYNTHETIC_CHAIN_ID;

        script.recordAdoption(plan);

        assertEq(
            RegistryWriter.read(SYNTHETIC_CHAIN_ID, "token"), CCT_TOKEN, "active.token must resolve the adopted token"
        );
        assertEq(
            RegistryWriter.read(SYNTHETIC_CHAIN_ID, "tokenPool"),
            CCT_POOL_200,
            "active.tokenPool must resolve the adopted pool"
        );
        assertEq(
            RegistryWriter.readDeployment(
                SYNTHETIC_CHAIN_ID, string.concat(plan.tokenSymbol, "_BurnMintTokenPool_2.0.0")
            ),
            CCT_POOL_200,
            "deployments entry keyed by the on-chain type and version"
        );
    }
}
