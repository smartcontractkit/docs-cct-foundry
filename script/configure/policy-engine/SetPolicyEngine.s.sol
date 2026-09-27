// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";

/**
 * @title SetPolicyEngine
 * @notice Script to point an AdvancedPoolHooks contract at an ACE Policy Engine on the same chain,
 *         or disconnect the engine with the zero address.
 * @dev Calls setPolicyEngine(newPolicyEngine) as the hooks owner. The hook calls attach() on the new
 *      engine, which starts ACE target detection. When an old engine is set, setPolicyEngine calls
 *      detach() on it first and reverts PolicyEngineDetachReverted if that call reverts; rerun with
 *      ALLOW_FAILED_DETACH=true to call setPolicyEngineAllowFailedDetach instead.
 *
 * Usage:
 *   POOL_HOOKS=0x... POLICY_ENGINE=0x... forge script script/configure/policy-engine/SetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   POOL_HOOKS=0x... POLICY_ENGINE=0x0000000000000000000000000000000000000000 forge script script/configure/policy-engine/SetPolicyEngine.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   POOL_HOOKS          - address of the AdvancedPoolHooks contract (alias > {CHAIN}_POOL_HOOKS > registry)
 *   POLICY_ENGINE       - address of the ACE Policy Engine on the same chain, or the zero address to disconnect
 *   ALLOW_FAILED_DETACH - true calls setPolicyEngineAllowFailedDetach, tolerating a reverting detach()
 *                         on the old engine (default false)
 */
contract SetPolicyEngine is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev The env-reading entrypoint: resolves the inputs and hands them to `runWith` below,
    ///      which carries all the behaviour. Tests drive `runWith` directly rather than exporting
    ///      POOL_HOOKS / POLICY_ENGINE, because `vm.setEnv` writes the whole forge PROCESS
    ///      environment and forge runs suites in parallel (see the note above
    ///      `BaseForkTest.deployTokenAndPoolFixture`). `runWith` rather than an overloaded `run`:
    ///      `forge script <path>` with no `--sig` refuses a contract whose ABI holds two `run`
    ///      entries, and no script in this repo overloads `run`.
    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        // POOL_HOOKS alias > {CHAIN}_POOL_HOOKS > registry active.poolHooks (no manual export needed).
        address hooksAddress = vm.envOr("POOL_HOOKS", helperConfig.getDeployedPoolHooks(chainId));
        runWith(hooksAddress, vm.envAddress("POLICY_ENGINE"), vm.envOr("ALLOW_FAILED_DETACH", false));
    }

    /// @notice Point the `AdvancedPoolHooks` at `hooksAddress` at the ACE Policy Engine
    ///         `newPolicyEngine`, or disconnect with the zero address. Drive it directly with
    ///         `--sig "runWith(address,address,bool)"` to bypass the environment entirely.
    function runWith(address hooksAddress, address newPolicyEngine, bool allowFailedDetach) public {
        if (address(helperConfig) == address(0)) {
            helperConfig = new HelperConfig();
        }
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        require(
            hooksAddress != address(0),
            string.concat(
                "AdvancedPoolHooks not deployed. Set POOL_HOOKS env var or ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_POOL_HOOKS."
            )
        );

        // Read the current engine before the write so the report can name what is being replaced.
        address currentEngine = AdvancedPoolHooks(hooksAddress).getPolicyEngine();
        _checkNewEngine(currentEngine, newPolicyEngine);

        console.log("");
        console.log("========================================");
        console.log(unicode"🔗 Set Policy Engine");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Pool Hooks:   ", vm.toString(hooksAddress)));
        console.log(string.concat("Action:       ", "Set policy engine"));
        console.log("========================================");
        console.log("");
        console.log(string.concat("Current Policy Engine: ", vm.toString(currentEngine)));
        console.log(string.concat("New Policy Engine:     ", vm.toString(newPolicyEngine)));
        if (newPolicyEngine == address(0)) {
            console.log("   The zero address disconnects the engine and stops policy checks.");
        }
        if (allowFailedDetach) {
            console.log("   ALLOW_FAILED_DETACH=true: a reverting detach() on the old engine is tolerated.");
            console.log("   The old engine keeps this hook listed as attached, so pointing back at it");
            console.log("   later reverts TargetAlreadyAttached until that engine drops the hook.");
        }
        console.log("");

        _executeCalls(
            allowFailedDetach
                ? CctActions._setPolicyEngineAllowFailedDetach(hooksAddress, newPolicyEngine)
                : CctActions._setPolicyEngine(hooksAddress, newPolicyEngine)
        );

        _logOperationOutcome(string.concat("set the policy engine on ", chainName));
        // hooks.policyEngine is a governance-critical roles{} field; the old declaration fails
        // roles-check until re-snapshotted.
        console.log(
            string.concat(
                _callsWereApplied() ? "Next:         " : "After the Safe executes: ",
                "make snapshot-chain CHAIN=",
                helperConfig.getSelectorName(chainId),
                " (records hooks.policyEngine in roles{})"
            )
        );
        console.log("========================================");
        console.log(string.concat("Pool Hooks:   ", helperConfig.getExplorerUrl(chainId, "/address/", hooksAddress)));
        console.log("========================================");
        console.log("");
    }

    /// @dev A same-address update is a silent no-op on the hook, and a codeless engine makes attach()
    ///      revert with empty data; refuse both before broadcasting.
    function _checkNewEngine(address currentEngine, address newPolicyEngine) internal view {
        require(
            newPolicyEngine != currentEngine,
            string.concat(
                "POLICY_ENGINE equals the current engine (",
                vm.toString(currentEngine),
                "). setPolicyEngine would be a no-op. Pass a different address."
            )
        );
        require(
            newPolicyEngine == address(0) || newPolicyEngine.code.length > 0,
            string.concat(
                "POLICY_ENGINE ",
                vm.toString(newPolicyEngine),
                " has no code on this chain. Pass the Policy Engine deployed on this chain, or 0x0 to disconnect."
            )
        );
    }
}
