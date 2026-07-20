// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

/**
 * @notice Initiates a two-step ownership transfer for any Ownable contract (a token pool, pool hooks,
 *         or a lockbox).
 * @dev This is step 1 of a two-step process. The new owner must run AcceptOwnership to complete it.
 *      Token pools, pool hooks, and lockboxes all use Chainlink's ConfirmedOwner / Ownable2Step
 *      pattern: the transfer is initiated here and does not take effect until the new owner accepts
 *      it. The contract at ADDRESS is treated as a generic IOwnable and its transferOwnership is
 *      called. If the contract exposes typeAndVersion(), it is used to label the console output.
 *
 *      This is a generic Ownable transfer. To move a token's top-level admin, use
 *      script/setup/token-roles/TransferTokenAdmin.s.sol instead: it is template-aware and handles a
 *      crosschain token's defaultAdmin, a burnmint token's DEFAULT_ADMIN_ROLE, and a factory token's
 *      owner. A token that exposes no owner() (a crosschain or burnmint token) reverts here with a
 *      pointer to that script.
 *
 * Required env vars:
 *   ADDRESS:   contract address of the Ownable entity
 *   NEW_OWNER: address of the new owner
 *
 * Usage:
 *   ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract TransferOwnership is EoaExecutor {
    HelperConfig public helperConfig;

    /// @dev Labels console output from the contract's typeAndVersion() when it exposes one; a plain
    ///      "Contract" otherwise. Purely cosmetic.
    function _entityLabel(address entityAddress) internal pure returns (string memory) {
        try ITypeAndVersion(entityAddress).typeAndVersion() returns (string memory tv) {
            return tv;
        } catch {
            return "Contract";
        }
    }

    /// @dev Reads owner(), turning the absence of an owner() (a crosschain or burnmint token) into a
    ///      clear pointer to the template-aware token-admin script rather than a raw low-level revert.
    function _requireOwner(IOwnable entity) internal returns (address) {
        try entity.owner() returns (address currentOwner) {
            return currentOwner;
        } catch {
            revert(
                "This contract exposes no owner(); if it is a token, move its admin with script/setup/token-roles/TransferTokenAdmin.s.sol"
            );
        }
    }

    function _padRight(string memory s, uint256 targetLen) internal pure returns (string memory) {
        bytes memory sb = bytes(s);
        if (sb.length >= targetLen) return s;
        bytes memory result = new bytes(targetLen);
        uint256 i;
        for (i = 0; i < sb.length; i++) {
            result[i] = sb[i];
        }
        for (; i < targetLen; i++) {
            result[i] = 0x20; // space
        }
        return string(result);
    }

    function run() external {
        helperConfig = new HelperConfig();

        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address entityAddress = vm.envAddress("ADDRESS");
        require(entityAddress != address(0), "ADDRESS must be set to a non-zero address");

        address newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0), "NEW_OWNER must be set to a non-zero address");

        string memory label = _entityLabel(entityAddress);

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"🔄 Transfer Ownership: ", label));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log("Action:       Transfer ownership");
        console.log("========================================");
        console.log("");

        _transferOwnership(chainId, chainName, label, entityAddress, newOwner);
    }

    function _transferOwnership(
        uint256 chainId,
        string memory chainName,
        string memory label,
        address entityAddress,
        address newOwner
    ) internal {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = _requireOwner(entity);

        console.log("Transfer Ownership Parameters:");
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));
        console.log(string.concat("  New Owner:     ", vm.toString(newOwner)));

        address signer = _broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        require(
            currentOwner == signer,
            string.concat(
                "Signer (",
                vm.toString(signer),
                ") is not the current owner (",
                vm.toString(currentOwner),
                "). Only the current owner can initiate an ownership transfer."
            )
        );

        console.log(string.concat("\n[Step 1] Transferring ownership on ", chainName));
        _executeCalls(CctActions._transferOwnership(entityAddress, newOwner));
        console.log(unicode"✅ Ownership transfer initiated successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Ownership Transfer Initiated on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat(
                _padRight(string.concat(label, ":"), 12),
                " ",
                helperConfig.getExplorerUrl(chainId, "/address/", entityAddress)
            )
        );
        console.log(string.concat("New Owner:   ", vm.toString(newOwner)));
        console.log("========================================");
        console.log("");
        console.log(
            string.concat(
                unicode"ℹ️  The new owner (",
                vm.toString(newOwner),
                ") must run AcceptOwnership with ADDRESS=",
                vm.toString(entityAddress),
                " to complete the transfer."
            )
        );
        console.log("");
    }
}
