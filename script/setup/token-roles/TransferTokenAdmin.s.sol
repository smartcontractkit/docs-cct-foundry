// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {TokenRoleScript} from "./TokenRoleScript.s.sol";
import {RolesProbes} from "../../../src/roles/RolesProbes.sol";

/**
 * @notice Moves the token's TOP-LEVEL admin (its template's own mechanism). This is the token-INTERNAL
 *         admin, not the TokenAdminRegistry cutover authority (that one moves through
 *         `TransferTokenAdminRole`/`AcceptAdminRole`). This script is the single home for moving a
 *         token's top-level admin, split into the two ceremony legs:
 *
 *         Step A (default, grant/begin-only, so the escape-hatch window stays open):
 *           - crosschain (`AccessControlDefaultAdminRules`): `beginDefaultAdminTransfer(NEW_ADMIN)`
 *           - burnmint (plain `AccessControl`): `grantRole(DEFAULT_ADMIN_ROLE, NEW_ADMIN)`, GRANT
 *             ONLY. The old holder's revoke is a separate, later step (the ceremony's batch C, after
 *             the completion gate), which keeps the escape-hatch window open: the deployer EOA keeps
 *             its rollback authority until the completion gate proves the Safe is executable, so a
 *             wrong or non-executable NEW_ADMIN stays recoverable.
 *           - factory (`Ownable2Step`): `transferOwnership(NEW_ADMIN)`
 *
 *         Step B (`ACCEPT=1`, run by the new admin, the Safe in MODE=safe):
 *           - crosschain: `acceptDefaultAdminTransfer()`
 *           - factory: `acceptOwnership()`
 *           - burnmint: refused by name, the grant model has no accept leg (step A is already
 *             effective).
 *
 *         BYO tokens are refused: the top-level admin mechanism of an unknown template is not
 *         guessable, and a wrong guess is irreversible.
 *
 * Required env vars:
 *   NEW_ADMIN: the recipient (step A only)
 *
 * Optional env vars:
 *   TOKEN:  token address (defaults to the {CHAIN}_TOKEN / registry resolution ladder)
 *   ACCEPT: set to 1 to run the accept leg (step B) instead of the transfer leg
 *
 * Usage:
 *   NEW_ADMIN=0xSafe \
 *     forge script script/setup/token-roles/TransferTokenAdmin.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ACCEPT=1 MODE=safe SAFE_ADDRESS=0xSafe BATCH_NAME=accept-token-admin \
 *     forge script script/setup/token-roles/TransferTokenAdmin.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
 */
contract TransferTokenAdmin is TokenRoleScript {
    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);
        HelperConfig.NetworkConfig memory config = helperConfig.getNetworkConfig(chainId);

        address token = _resolveToken(config, chainId);

        RolesProbes.TokenTemplate template = RolesProbes._detectTemplate(token);
        require(
            template != RolesProbes.TokenTemplate.BYO,
            "byo token: the top-level admin mechanism of an unknown template is not guessable - move it with the token's own tooling"
        );

        bool acceptLeg = _acceptLeg();
        address actor = _executingAccount();

        console.log("");
        console.log("========================================");
        console.log(unicode"👑 Transfer Token Admin (token-internal top-level admin)");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Token:        ", vm.toString(token)));
        console.log(string.concat("Template:     ", RolesProbes._templateName(template)));
        console.log(string.concat("Leg:          ", acceptLeg ? "accept (step B)" : "transfer (step A)"));
        console.log(string.concat("Actor:        ", vm.toString(actor)));
        console.log("========================================");
        console.log("");

        if (acceptLeg) {
            _accept(chainName, token, template, actor);
        } else {
            _transfer(chainName, token, template, actor);
        }

        console.log("");
        console.log("========================================");
        // The banner reflects the exact success path taken. The burnmint grant-only path leaves the old
        // holder's DEFAULT_ADMIN_ROLE in place (revoked later by the ceremony's batch), while
        // crosschain/factory begin a native two-step transfer that the new admin completes with ACCEPT=1.
        bool twoStepInitiated;
        string memory outcome;
        if (acceptLeg) {
            outcome = "Accepted";
        } else if (template == RolesProbes.TokenTemplate.BurnMintERC20) {
            outcome = "Granted (the old holder retains DEFAULT_ADMIN_ROLE; the revoke is the ceremony's later batch)";
        } else {
            outcome = "Transfer Initiated";
            twoStepInitiated = true;
        }
        console.log(string.concat(unicode"✅ Token Admin ", outcome, "!"));
        console.log("========================================");
        console.log(string.concat("Token: ", helperConfig.getExplorerUrl(chainId, "/address/", token)));
        if (twoStepInitiated) {
            console.log("Next: the new admin runs this same script with ACCEPT=1 to complete the transfer.");
        }
        console.log("========================================");
        console.log("");
    }

    /// @dev Virtual input seams (like `_executionMode`): the env vars are process-wide, so tests pin
    ///      inputs via overrides instead of `vm.setEnv` (which would race parallel suites).
    function _newAdmin() internal view virtual returns (address) {
        return vm.envAddress("NEW_ADMIN");
    }

    function _acceptLeg() internal view virtual returns (bool) {
        return vm.envOr("ACCEPT", false);
    }

    function _transfer(string memory chainName, address token, RolesProbes.TokenTemplate template, address actor)
        private
    {
        address newAdmin = _newAdmin();
        require(newAdmin != address(0), "NEW_ADMIN must be set to a non-zero address");
        console.log(string.concat("New Admin:    ", vm.toString(newAdmin)));

        if (template == RolesProbes.TokenTemplate.CrossChainToken) {
            (, address current) = RolesProbes._tryAddress(token, "defaultAdmin()");
            require(
                current == actor,
                string.concat(
                    "Executing account (",
                    vm.toString(actor),
                    ") is not the token's defaultAdmin (",
                    vm.toString(current),
                    ")."
                )
            );
            console.log(string.concat("\n[Step 1] beginDefaultAdminTransfer (two-step) on ", chainName));
            _executeCalls(CctActions._beginDefaultAdminTransfer(token, newAdmin));
            console.log(unicode"✅ Transfer initiated! The new admin must run this script with ACCEPT=1.");
            return;
        }
        if (template == RolesProbes.TokenTemplate.BurnMintERC20) {
            require(
                RolesProbes._hasRole(token, RolesProbes.DEFAULT_ADMIN_ROLE, actor),
                string.concat(
                    "Executing account (", vm.toString(actor), ") does not hold DEFAULT_ADMIN_ROLE on this token."
                )
            );
            console.log(
                unicode"⚠️  burnmint (plain AccessControl): DEFAULT_ADMIN_ROLE uses a ONE-STEP grant model. The grant takes effect immediately (there is no ACCEPT=1 step) and does NOT remove the current admin. To complete a full handoff, the new admin runs RevokeTokenRole ROLE=defaultAdmin HOLDER=<old admin>."
            );
            console.log(string.concat("\n[Step 1] grantRole(DEFAULT_ADMIN_ROLE) - GRANT ONLY - on ", chainName));
            _executeCalls(CctActions._grantRole(token, RolesProbes.DEFAULT_ADMIN_ROLE, newAdmin));
            console.log(
                unicode"✅ Granted! The old holder keeps DEFAULT_ADMIN_ROLE until the ceremony's revoke batch (after the completion gate)."
            );
            return;
        }
        // factory (Ownable2Step)
        (, address owner_) = RolesProbes._tryAddress(token, "owner()");
        require(
            owner_ == actor,
            string.concat(
                "Executing account (", vm.toString(actor), ") is not the token owner (", vm.toString(owner_), ")."
            )
        );
        console.log(string.concat("\n[Step 1] transferOwnership (two-step) on ", chainName));
        _executeCalls(CctActions._transferOwnership(token, newAdmin));
        console.log(unicode"✅ Transfer initiated! The new owner must run this script with ACCEPT=1.");
    }

    function _accept(string memory chainName, address token, RolesProbes.TokenTemplate template, address actor)
        private
    {
        if (template == RolesProbes.TokenTemplate.CrossChainToken) {
            (, address pending) = RolesProbes._tryAddress(token, "pendingDefaultAdmin()");
            require(
                pending == actor,
                string.concat(
                    "Executing account (",
                    vm.toString(actor),
                    ") is not the pending defaultAdmin (",
                    vm.toString(pending),
                    ")."
                )
            );
            console.log(string.concat("\n[Step 1] acceptDefaultAdminTransfer on ", chainName));
            _executeCalls(CctActions._acceptDefaultAdminTransfer(token));
            console.log(unicode"✅ Default admin accepted!");
            return;
        }
        require(
            template != RolesProbes.TokenTemplate.BurnMintERC20,
            "burnmint token: the grant model has no accept leg - the step-A grantRole is already effective"
        );
        // factory (Ownable2Step)
        (bool hasPending, address pendingOwner) = RolesProbes._tryAddress(token, "pendingOwner()");
        if (hasPending) {
            require(
                pendingOwner == actor,
                string.concat(
                    "Executing account (",
                    vm.toString(actor),
                    ") is not the pending owner (",
                    vm.toString(pendingOwner),
                    ")."
                )
            );
        }
        console.log(string.concat("\n[Step 1] acceptOwnership on ", chainName));
        _executeCalls(CctActions._acceptOwnership(token));
        console.log(unicode"✅ Ownership accepted!");
    }
}
