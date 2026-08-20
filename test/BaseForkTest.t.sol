// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {DeployToken} from "../script/deploy/DeployToken.s.sol";
import {DeployBurnMintTokenPool} from "../script/deploy/DeployBurnMintTokenPool.s.sol";
import {CctActions} from "../src/actions/CctActions.sol";
import {RolesProbes} from "../src/roles/RolesProbes.sol";

/// @title BaseForkTest
/// @notice Shared base for Ethereum Sepolia fork tests.
///
/// RPC resolution: the ETHEREUM_SEPOLIA_RPC_URL environment variable takes priority when
/// set (e.g. a private/paid endpoint). When it is not set, the test falls back to a
/// list of public Sepolia RPC endpoints, trying each in order so a single flaky provider
/// does not fail the suite. This makes `forge test` work with zero configuration.
///
/// Fixture: `deployTokenFixture` / `deployTokenAndPoolFixture` deploy the repo's own
/// `CrossChainToken` + `BurnMintTokenPool` by running the actual deploy scripts
/// (`DeployToken`, `DeployBurnMintTokenPool`), so tests exercise the same code paths
/// users run. The recorder's writes are inert here: under `forge test` nothing is sent, so neither the
/// `history/` ledger nor the project store is touched, and the fixtures resolve the deployed address
/// from the broadcaster's nonce instead (`vm.computeCreateAddress`).
abstract contract BaseForkTest is Test {
    string internal constant TOKEN_JSON_PATH = "script/input/token.json";

    HelperConfig internal helperConfig;
    HelperConfig.NetworkConfig internal networkConfig;

    function setUp() public virtual {
        _createSepoliaFork();
        helperConfig = new HelperConfig();
        networkConfig = helperConfig.getNetworkConfig(block.chainid);
    }

    /// @dev Creates and selects a Sepolia fork. ETHEREUM_SEPOLIA_RPC_URL overrides;
    /// otherwise public endpoints are tried in order until one serves the fork.
    function _createSepoliaFork() internal {
        string memory rpcOverride = vm.envOr("ETHEREUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcOverride).length > 0) {
            // Name the SOURCE of a bad override - the raw fork error never says which env var fed it.
            try vm.createSelectFork(rpcOverride) returns (uint256) {
                return;
            } catch {
                revert(
                    "BaseForkTest: fork failed on the ETHEREUM_SEPOLIA_RPC_URL override - check ETHEREUM_SEPOLIA_RPC_URL in your .env"
                );
            }
        }

        string[3] memory publicRpcs = [
            "https://ethereum-sepolia-rpc.publicnode.com",
            "https://sepolia.drpc.org",
            "https://sepolia.gateway.tenderly.co"
        ];
        for (uint256 i = 0; i < publicRpcs.length; i++) {
            try vm.createSelectFork(publicRpcs[i]) returns (uint256) {
                return;
            } catch {
                emit log_string(string.concat("Public Sepolia RPC unavailable, trying next: ", publicRpcs[i]));
            }
        }
        revert("BaseForkTest: no Sepolia RPC available (set ETHEREUM_SEPOLIA_RPC_URL to override)");
    }

    /// @dev Deploys the token by running the repo's DeployToken script. The deployed address
    /// is resolved deterministically from the broadcaster's nonce (CREATE address) rather than by
    /// reading a file back: under `forge test` the script records nothing, so there is no file to read.
    function deployTokenFixture() internal returns (address token) {
        address broadcaster = _scriptBroadcaster();
        uint256 nonceBefore = vm.getNonce(broadcaster);
        new DeployToken().run();
        token = vm.computeCreateAddress(broadcaster, nonceBefore);
        assertGt(token.code.length, 0, "token fixture not deployed at computed address");
    }

    /// @dev Deploys token + burn/mint pool through the repo's deploy scripts.
    /// The TOKEN env var is how DeployBurnMintTokenPool receives the token address
    /// (same interface users drive on the command line). Note vm.setEnv is process-wide;
    /// this stays safe under parallel suites because the fixture is deterministic, so
    /// every suite sets the same value.
    ///
    /// POOL_HOOKS is pinned for a different reason: to make the fixture INDEPENDENT of the developer's
    /// own deploy state. Unset, `DeployBurnMintTokenPool` defaults it from `HelperConfig`, which reads
    /// `addresses.active.poolHooks` in `project/<chain>.json` - correct for a real deploy, wrong for a
    /// fixture. Setting the variable at all suppresses that default (`envOr` prefers any set value), and
    /// zero is what the script treats as "no hooks". Unlike the `TOKEN` pin above, which is safe because
    /// every suite computes the same address, this one is safe because zero is indistinguishable from
    /// unset to every other reader - so pinning it process-wide changes no other suite's resolution.
    ///
    /// Without the pin, a store recording a `poolHooks` address builds the fixture pool around it and
    /// the roles tests fail against the roles engine instead. Whether it has CODE is irrelevant - a
    /// deployed contract that answers none of the five hooks getters fails identically to a codeless
    /// one; what matters is how much of that surface answers.
    function deployTokenAndPoolFixture() internal returns (address token, address pool) {
        token = deployTokenFixture();
        vm.setEnv("TOKEN", vm.toString(token));
        vm.setEnv("POOL_HOOKS", vm.toString(address(0)));
        address broadcaster = _scriptBroadcaster();
        uint256 nonceBefore = vm.getNonce(broadcaster);
        new DeployBurnMintTokenPool().run();
        pool = vm.computeCreateAddress(broadcaster, nonceBefore);
        assertGt(pool.code.length, 0, "pool fixture not deployed at computed address");
        // Catches a dropped pin. It fires for any recorded hooks address, but only a developer with one
        // in their store would ever see it - CI's store is empty, so the pin is otherwise uncovered.
        (bool okHooks, address hooks) = RolesProbes._tryAddress(pool, "getAdvancedPoolHooks()");
        assertTrue(okHooks, "the fixture pool must expose getAdvancedPoolHooks() for the check below to mean anything");
        assertEq(hooks, address(0), "fixture pool must not inherit hooks from a real store");
    }

    /// @dev Returns the sender the deploy scripts will broadcast (prank) with in tests,
    /// discovered the same way the scripts do rather than hardcoding forge's default sender.
    function _scriptBroadcaster() internal returns (address broadcaster) {
        vm.startBroadcast();
        (, broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
    }

    /// @dev Executes a `CctActions.Call[]` in order, each pranked as `sender` - the exact `Call[]` the
    /// scripts hand to `EoaExecutor._executeCalls`, so a test proves the action-layer calldata
    /// against on-chain getters. Reverts (with the underlying reason) on the first failing call.
    function _exec(address sender, CctActions.Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(sender);
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
