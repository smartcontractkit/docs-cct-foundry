// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts@5.3.0/access/AccessControl.sol";

/// @notice Test tokens exercising each `ClaimPathDetector` branch. Shared by the detector unit test and
///         the fork/Safe registration tests so the claim-path fixtures live in one place.

/// @notice A pure OZ AccessControl token: it exposes `DEFAULT_ADMIN_ROLE` (via ERC165) but neither
///         `getCCIPAdmin()` nor `owner()`, so it is registrable only through the AccessControl claim path.
contract AccessControlOnlyToken is ERC20, AccessControl {
    constructor(address admin) ERC20("AccessControl Only", "ACO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

/// @notice A token that reports its admin only through `getCCIPAdmin()` (the first probe path).
contract GetCCIPAdminOnlyToken {
    address internal immutable i_admin;

    constructor(address admin) {
        i_admin = admin;
    }

    function getCCIPAdmin() external view returns (address) {
        return i_admin;
    }
}

/// @notice A token that reports its admin only through `owner()` (the second probe path).
contract OwnerOnlyToken {
    address internal immutable i_owner;

    constructor(address owner_) {
        i_owner = owner_;
    }

    function owner() external view returns (address) {
        return i_owner;
    }
}

/// @notice A token supporting none of the three registration paths, which the detector must reject.
contract UnsupportedToken {
    uint256 internal placeholder;

    function ping() external {
        placeholder = 1;
    }
}
