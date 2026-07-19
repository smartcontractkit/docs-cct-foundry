// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {HelperConfig} from "../../HelperConfig.s.sol";
import {CctActions} from "../../../src/actions/CctActions.sol";
import {EoaExecutor} from "../../../src/base/EoaExecutor.s.sol";
import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";

/**
 * @notice Initiates a two-step ownership transfer for a generic Ownable entity (a token pool, pool
 *         hooks, or a lockbox).
 * @dev This is step 1 of a two-step process. The new owner must run AcceptOwnership to complete it.
 *      tokenPool, poolHooks, and lockBox all use Chainlink's ConfirmedOwner / Ownable2Step pattern:
 *      the transfer is initiated here and does not take effect until the new owner accepts it. The
 *      contract at ADDRESS is treated as a generic IOwnable and its transferOwnership is called.
 *
 *      To move a token's top-level admin (defaultAdmin / owner / DEFAULT_ADMIN_ROLE), use
 *      script/setup/token-roles/TransferTokenAdmin.s.sol. This script does not handle tokens.
 *
 * Required env vars:
 *   ENTITY_TYPE: one of tokenPool, poolHooks, lockBox (optional; omit for a generic IOwnable)
 *   ADDRESS:     contract address of the entity
 *   NEW_OWNER:   address of the new owner
 *
 * Usage:
 *   ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=tokenPool ADDRESS=0xYourPool NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=poolHooks ADDRESS=0xYourHooks NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *   ENTITY_TYPE=lockBox ADDRESS=0xYourLockBox NEW_OWNER=0xNewOwner \
 *     forge script script/setup/transfer-ownership/TransferOwnership.s.sol \
 *     --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * If ENTITY_TYPE is omitted, the contract at ADDRESS is treated as a generic IOwnable (same as tokenPool/poolHooks/lockBox).
 */
contract TransferOwnership is EoaExecutor {
    HelperConfig public helperConfig;

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _entityLabel(string memory entityType) internal pure returns (string memory) {
        if (bytes(entityType).length == 0) return "Contract";
        if (_eq(entityType, "token")) {
            revert(
                "ENTITY_TYPE=token is not handled here; move a token's top-level admin with script/setup/token-roles/TransferTokenAdmin.s.sol"
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

        address newOwner = vm.envAddress("NEW_OWNER");
        require(newOwner != address(0), "NEW_OWNER must be set to a non-zero address");

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"🔄 Transfer ", label, " Ownership"));
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("Action:       Transfer ", _entityActionLabel(entityType), " ownership"));
        console.log("========================================");
        console.log("");

        _transferSimpleOwnership(chainId, chainName, entityType, label, entityAddress, newOwner);
    }

    function _transferSimpleOwnership(
        uint256 chainId,
        string memory chainName,
        string memory entityType,
        string memory label,
        address entityAddress,
        address newOwner
    ) internal {
        IOwnable entity = IOwnable(entityAddress);
        address currentOwner = entity.owner();

        console.log(string.concat("Transfer ", label, " Ownership Parameters:"));
        console.log(string.concat("  ", _padRight(string.concat(label, ":"), 14), " ", vm.toString(entityAddress)));
        console.log(string.concat("  Current Owner: ", vm.toString(currentOwner)));
        console.log(string.concat("  New Owner:     ", vm.toString(newOwner)));

        address signer = broadcaster();
        console.log(string.concat("  Signer:        ", vm.toString(signer)));
        console.log("");

        require(
            currentOwner == signer,
            string.concat(
                "Signer (",
                vm.toString(signer),
                ") is not the current ",
                _entityActionLabel(entityType),
                " owner (",
                vm.toString(currentOwner),
                "). Only the current owner can initiate an ownership transfer."
            )
        );

        console.log(
            string.concat("\n[Step 1] Transferring ", _entityActionLabel(entityType), " ownership on ", chainName)
        );
        executeCalls(CctActions.transferOwnership(entityAddress, newOwner));
        console.log(string.concat(unicode"✅ ", label, " ownership transfer initiated successfully!"));

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ ", label, " Ownership Transfer Initiated on ", chainName, "!"));
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
        string memory entityTypeHint = bytes(entityType).length > 0
            ? string.concat("ENTITY_TYPE=", entityType, " ADDRESS=", vm.toString(entityAddress))
            : string.concat("ADDRESS=", vm.toString(entityAddress));
        console.log(
            string.concat(
                unicode"ℹ️  The new owner (",
                vm.toString(newOwner),
                ") must run AcceptOwnership with ",
                entityTypeHint,
                " to complete the transfer."
            )
        );
        console.log("");
    }
}
