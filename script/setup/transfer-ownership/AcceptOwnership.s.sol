// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";
import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

/**
 * @notice Completes a two-step ownership transfer initiated by TransferOwnership for any Ownable
 *         contract (a token pool, pool hooks, or a lockbox).
 * @dev Token pools, pool hooks, and lockboxes all use Chainlink's ConfirmedOwner / Ownable2Step
 *      pattern: this script calls acceptOwnership() on the entity at ADDRESS. The signer must be the
 *      address that was set as the pending owner; acceptOwnership reverts on-chain otherwise. If the
 *      contract exposes typeAndVersion(), it is used to label the console output.
 *
 *      This is a generic Ownable transfer. To accept a token's top-level admin, use
 *      script/setup/token-roles/TransferTokenAdmin.s.sol with ACCEPT=1 instead: it is template-aware.
 *      A token that exposes no owner() (a crosschain or burnmint token) reverts here with a pointer to
 *      that script.
 *
 * Required env vars:
 *   ADDRESS: contract address of the Ownable entity
 *
 * Usage:
 *   ADDRESS=0xYourPool \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 */
contract AcceptOwnership is EoaExecutor {
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
                "This contract exposes no owner(); if it is a token, accept its admin with script/setup/token-roles/TransferTokenAdmin.s.sol (set ACCEPT=1)"
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

        string memory label = _entityLabel(entityAddress);

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"👑 Accept Ownership: ", label));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log("Action:       Accept ownership");
        console.log("========================================");
        console.log("");

        _acceptOwnership(chainId, chainName, label, entityAddress);
    }

    function _acceptOwnership(uint256 chainId, string memory chainName, string memory label, address entityAddress)
        internal
    {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = _requireOwner(entity);

        console.log("Accept Ownership Parameters:");
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));

        address signer = _broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        console.log(string.concat("\n[Step 1] Accepting ownership on ", chainName));
        // acceptOwnership reverts on-chain if the signer is not the pending owner
        _executeCalls(CctActions._acceptOwnership(entityAddress));
        console.log(unicode"✅ Ownership accepted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Ownership Accepted on ", chainName, "!"));
        console.log("========================================");
        console.log(
            string.concat(
                _padRight(string.concat(label, ":"), 11),
                " ",
                helperConfig.getExplorerUrl(chainId, "/address/", entityAddress)
            )
        );
        console.log(string.concat("New Owner:  ", vm.toString(signer)));
        console.log("========================================");
        console.log("");
    }
}
