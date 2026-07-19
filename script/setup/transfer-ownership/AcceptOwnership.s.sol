// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";

/**
 * @notice Completes a two-step ownership transfer initiated by TransferOwnership for a generic Ownable
 *         entity (a token pool, pool hooks, or a lockbox).
 * @dev tokenPool, poolHooks, and lockBox all use Chainlink's ConfirmedOwner / Ownable2Step pattern:
 *      this script calls acceptOwnership() on the entity at ADDRESS. The signer must be the address
 *      that was set as the pending owner; acceptOwnership reverts on-chain otherwise.
 *
 *      To accept a token's top-level admin (defaultAdmin / owner / DEFAULT_ADMIN_ROLE), use
 *      script/setup/token-roles/TransferTokenAdmin.s.sol with ACCEPT=1. This script does not handle
 *      tokens.
 *
 * Required env vars:
 *   ENTITY_TYPE: one of tokenPool, poolHooks, lockBox (optional; omit for a generic IOwnable)
 *   ADDRESS:     contract address of the entity
 *
 * Usage:
 *   ADDRESS=0xYourPool \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=tokenPool ADDRESS=0xYourPool \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox \
 *     forge script script/setup/transfer-ownership/AcceptOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * If ENTITY_TYPE is omitted, the contract at ADDRESS is treated as a generic IOwnable (same as tokenPool/poolHooks/lockBox).
 */
contract AcceptOwnership is EoaExecutor {
    HelperConfig public helperConfig;

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _entityLabel(string memory entityType) internal pure returns (string memory) {
        if (bytes(entityType).length == 0) return "Contract";
        if (_eq(entityType, "token")) {
            revert(
                "ENTITY_TYPE=token is not handled here; accept a token's top-level admin with script/setup/token-roles/TransferTokenAdmin.s.sol (set ACCEPT=1)"
            );
        }
        if (_eq(entityType, "tokenPool")) return "Token Pool";
        if (_eq(entityType, "poolHooks")) return "Pool Hooks";
        if (_eq(entityType, "lockBox")) return "LockBox";
        revert(string.concat("Invalid ENTITY_TYPE \"", entityType, "\". Valid values: tokenPool, poolHooks, lockBox"));
    }

    function _entityActionLabel(string memory entityType) internal pure returns (string memory) {
        if (bytes(entityType).length == 0) return "contract";
        if (_eq(entityType, "tokenPool")) return "token pool";
        if (_eq(entityType, "poolHooks")) return "pool hooks";
        return "lockbox"; // lockBox
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

        string memory entityType = vm.envOr("ENTITY_TYPE", string(""));
        string memory label = _entityLabel(entityType); // also validates entityType

        address entityAddress = vm.envAddress("ADDRESS");
        require(entityAddress != address(0), "ADDRESS must be set to a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"👑 Accept ", label, " Ownership"));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       Accept ", _entityActionLabel(entityType), " ownership"));
        console.log("========================================");
        console.log("");

        _acceptSimpleOwnership(chainId, chainName, entityType, label, entityAddress);
    }

    function _acceptSimpleOwnership(
        uint256 chainId,
        string memory chainName,
        string memory entityType,
        string memory label,
        address entityAddress
    ) internal {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = entity.owner();

        console.log(string.concat("Accept ", label, " Ownership Parameters:"));
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));

        address signer = broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        console.log(string.concat("\n[Step 1] Accepting ", _entityActionLabel(entityType), " ownership on ", chainName));
        // acceptOwnership reverts on-chain if the signer is not the pending owner
        executeCalls(CctActions.acceptOwnership(entityAddress));
        console.log(unicode"✅ Ownership accepted successfully!");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ ", label, " Ownership Accepted on ", chainName, "!"));
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
