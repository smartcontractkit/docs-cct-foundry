// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimPathDetector} from "../../script/setup/ClaimPathDetector.sol";
import {
    AccessControlOnlyToken,
    GetCCIPAdminOnlyToken,
    OwnerOnlyToken,
    UnsupportedToken
} from "../fixtures/ClaimPathMocks.sol";

/// @notice Unit tests for the shared claim-path probe. No fork: the probe only staticcalls the token, so
///         locally deployed mocks exercise the real detection and preflight code directly.
///
/// The `getCCIPAdmin()` and `owner()` paths are asserted to be selected exactly as the claim scripts
/// select them, and the AccessControl path is covered on both its success and failure branches.
contract ClaimPathDetectionTest is Test {
    address internal constant ADMIN = address(uint160(uint256(keccak256("claim-path.admin"))));
    address internal constant OTHER = address(uint160(uint256(keccak256("claim-path.other"))));

    /// @dev Thin wrappers so the internal library functions cross an external boundary, which is what
    ///      lets `vm.expectRevert` observe their reverts.
    function detect(address token) external view returns (ClaimPathDetector.ClaimPath path, address admin) {
        return ClaimPathDetector._detect(token);
    }

    function requireExpectedAdmin(
        ClaimPathDetector.ClaimPath path,
        address token,
        address reportedAdmin,
        address expectedAdmin
    ) external view {
        ClaimPathDetector._requireExpectedAdmin(path, token, reportedAdmin, expectedAdmin);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // detect()
    // ─────────────────────────────────────────────────────────────────────────

    function test_Detect_GetCCIPAdminPath() external {
        address token = address(new GetCCIPAdminOnlyToken(ADMIN));
        (ClaimPathDetector.ClaimPath path, address admin) = this.detect(token);
        assertEq(uint256(path), uint256(ClaimPathDetector.ClaimPath.GetCCIPAdmin), "must select getCCIPAdmin path");
        assertEq(admin, ADMIN, "getCCIPAdmin path must report the token's CCIP admin");
    }

    function test_Detect_OwnerPath() external {
        address token = address(new OwnerOnlyToken(ADMIN));
        (ClaimPathDetector.ClaimPath path, address admin) = this.detect(token);
        assertEq(uint256(path), uint256(ClaimPathDetector.ClaimPath.Owner), "must select owner path");
        assertEq(admin, ADMIN, "owner path must report the token's owner");
    }

    function test_Detect_AccessControlPath() external {
        address token = address(new AccessControlOnlyToken(ADMIN));
        (ClaimPathDetector.ClaimPath path, address admin) = this.detect(token);
        assertEq(
            uint256(path),
            uint256(ClaimPathDetector.ClaimPath.AccessControlDefaultAdmin),
            "must select the AccessControl path for a token with neither getCCIPAdmin() nor owner()"
        );
        assertEq(admin, address(0), "AccessControl path has no single admin getter");
    }

    function test_Detect_UnsupportedToken_Reverts() external {
        address token = address(new UnsupportedToken());
        vm.expectRevert(bytes("Token must implement getCCIPAdmin(), owner(), or OZ AccessControl (DEFAULT_ADMIN_ROLE)"));
        this.detect(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // methodLabel()
    // ─────────────────────────────────────────────────────────────────────────

    function test_MethodLabel_AllPaths() external pure {
        assertEq(ClaimPathDetector._methodLabel(ClaimPathDetector.ClaimPath.GetCCIPAdmin), "getCCIPAdmin()");
        assertEq(ClaimPathDetector._methodLabel(ClaimPathDetector.ClaimPath.Owner), "owner()");
        assertEq(
            ClaimPathDetector._methodLabel(ClaimPathDetector.ClaimPath.AccessControlDefaultAdmin),
            "AccessControl DEFAULT_ADMIN_ROLE"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // requireExpectedAdmin()
    // ─────────────────────────────────────────────────────────────────────────

    function test_RequireExpectedAdmin_AccessControl_HolderPasses() external {
        address token = address(new AccessControlOnlyToken(ADMIN));
        this.requireExpectedAdmin(ClaimPathDetector.ClaimPath.AccessControlDefaultAdmin, token, address(0), ADMIN);
    }

    function test_RequireExpectedAdmin_AccessControl_NonHolderReverts() external {
        address token = address(new AccessControlOnlyToken(ADMIN));
        vm.expectRevert(bytes("Expected admin does not hold DEFAULT_ADMIN_ROLE on the token"));
        this.requireExpectedAdmin(ClaimPathDetector.ClaimPath.AccessControlDefaultAdmin, token, address(0), OTHER);
    }

    function test_RequireExpectedAdmin_ReportedAdmin_MatchPasses() external view {
        this.requireExpectedAdmin(ClaimPathDetector.ClaimPath.GetCCIPAdmin, address(0), ADMIN, ADMIN);
        this.requireExpectedAdmin(ClaimPathDetector.ClaimPath.Owner, address(0), ADMIN, ADMIN);
    }

    function test_RequireExpectedAdmin_ReportedAdmin_MismatchReverts() external {
        vm.expectRevert(bytes("Admin of token doesn't match the expected admin address"));
        this.requireExpectedAdmin(ClaimPathDetector.ClaimPath.GetCCIPAdmin, address(0), ADMIN, OTHER);
    }
}
