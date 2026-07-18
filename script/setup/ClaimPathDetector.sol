// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/contracts/interfaces/IGetCCIPAdmin.sol";
import {IOwner} from "@chainlink/contracts-ccip/contracts/interfaces/IOwner.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.3.0/access/IAccessControl.sol";
import {AccessControl} from "@openzeppelin/contracts@5.3.0/access/AccessControl.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";

/// @notice Probes which `RegistryModuleOwnerCustom` self-registration path a token supports, so the
///         claim scripts (`ClaimAdmin`, `ClaimAndAcceptAdmin`) share one probe instead of duplicating it.
///         The registry exposes three self-register methods, matched here in a fixed precedence:
///         `getCCIPAdmin()` first, then `owner()`, then OZ AccessControl `DEFAULT_ADMIN_ROLE`.
library ClaimPathDetector {
    /// @notice The self-registration path a token supports, in probe precedence order.
    enum ClaimPath {
        GetCCIPAdmin,
        Owner,
        AccessControlDefaultAdmin
    }

    /// @notice Detect the supported claim path for `token`.
    /// @param token The token to probe.
    /// @return path The supported claim path.
    /// @return admin The single admin the token reports for the `getCCIPAdmin()` / `owner()` paths.
    ///         `address(0)` for the AccessControl path, whose admin is any `DEFAULT_ADMIN_ROLE` holder
    ///         rather than a single getter, so the caller checks role membership instead.
    function detect(address token) internal view returns (ClaimPath path, address admin) {
        // getCCIPAdmin() is preferred.
        try IGetCCIPAdmin(token).getCCIPAdmin() returns (address ccipAdmin) {
            return (ClaimPath.GetCCIPAdmin, ccipAdmin);
        } catch {
            // owner() is the next path.
            try IOwner(token).owner() returns (address owner) {
                return (ClaimPath.Owner, owner);
            } catch {
                // Final path: an OZ AccessControl token, detected via ERC165. Its admin is any
                // DEFAULT_ADMIN_ROLE holder, so no single admin address is returned here.
                try IERC165(token).supportsInterface(type(IAccessControl).interfaceId) returns (bool supported) {
                    if (supported) {
                        return (ClaimPath.AccessControlDefaultAdmin, address(0));
                    }
                } catch {}
                revert("Token must implement getCCIPAdmin(), owner(), or OZ AccessControl (DEFAULT_ADMIN_ROLE)");
            }
        }
    }

    /// @notice The operator-facing label for a claim path, used in the claim scripts' console output.
    function methodLabel(ClaimPath path) internal pure returns (string memory) {
        if (path == ClaimPath.GetCCIPAdmin) {
            return "getCCIPAdmin()";
        }
        if (path == ClaimPath.Owner) {
            return "owner()";
        }
        return "AccessControl DEFAULT_ADMIN_ROLE";
    }

    /// @notice Preflight the expected admin against the token for the resolved path. The `getCCIPAdmin()`
    ///         and `owner()` paths require the token's reported admin to equal the expected admin. The
    ///         AccessControl path mirrors the registry: it reads the token's `DEFAULT_ADMIN_ROLE` and
    ///         requires the expected admin to hold that role.
    /// @param path The resolved claim path.
    /// @param token The token being registered.
    /// @param reportedAdmin The admin the token reported for the `getCCIPAdmin()` / `owner()` paths
    ///        (ignored for the AccessControl path).
    /// @param expectedAdmin The account expected to register the token (the executing account by default).
    function requireExpectedAdmin(ClaimPath path, address token, address reportedAdmin, address expectedAdmin)
        internal
        view
    {
        if (path == ClaimPath.AccessControlDefaultAdmin) {
            bytes32 defaultAdminRole = AccessControl(token).DEFAULT_ADMIN_ROLE();
            require(
                AccessControl(token).hasRole(defaultAdminRole, expectedAdmin),
                "Expected admin does not hold DEFAULT_ADMIN_ROLE on the token"
            );
        } else {
            require(reportedAdmin == expectedAdmin, "Admin of token doesn't match the expected admin address");
        }
    }
}
