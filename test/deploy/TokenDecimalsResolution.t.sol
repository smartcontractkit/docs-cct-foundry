// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeploymentUtils} from "../../script/utils/DeploymentUtils.s.sol";

/// @dev A token with no `decimals()` at all: the call reverts, which ERC20 permits.
contract NoDecimalsToken {}

contract SixDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice How the pool deploys establish the token-decimals constructor argument.
///
/// The pool stores the value immutable and scales every cross-chain amount with it, while `decimals()`
/// is optional in ERC20 and the pool itself treats an on-chain read as a cross-check only. So: the
/// token's answer when it gives one, an explicit DECIMALS when it does not, agreement required when
/// both exist, refusal when neither. The decision is pinned through `_establishDecimals`, which takes
/// the DECIMALS value as an argument: `vm.setEnv` is process-wide while tests run in parallel, and the
/// deploy fork tests read the same variable, so these tests never touch the environment.
contract TokenDecimalsResolutionTest is Test {
    uint256 internal constant UNSET = DeploymentUtils.DECIMALS_UNSET;

    function test_ReadDecimals_AnswersAndAbsenceLookDistinct() public {
        (bool okSix, uint8 six) = DeploymentUtils._readDecimals(address(new SixDecimalsToken()));
        assertTrue(okSix);
        assertEq(six, 6);
        (bool okNone,) = DeploymentUtils._readDecimals(address(new NoDecimalsToken()));
        assertFalse(okNone, "a token without the optional getter reads as unread, not as zero");
    }

    function test_EstablishDecimals_TokenAnswerAloneIsUsed() public pure {
        assertEq(DeploymentUtils._establishDecimals(true, 6, UNSET), 6);
    }

    function test_EstablishDecimals_SuppliedAloneIsUsed() public pure {
        assertEq(DeploymentUtils._establishDecimals(false, 0, 9), 9, "DECIMALS covers a token without decimals()");
    }

    function test_EstablishDecimals_AgreementIsAccepted() public pure {
        assertEq(DeploymentUtils._establishDecimals(true, 6, 6), 6);
    }

    function test_EstablishDecimals_NeitherSourceRefuses() public {
        vm.expectRevert(
            bytes("The token does not answer decimals(): set DECIMALS=<n> to the token's decimals to deploy its pool")
        );
        this.establish(false, 0, UNSET);
    }

    /// @dev The same cross-check the pool constructor makes (`InvalidDecimalArgs`), surfaced before
    ///      the broadcast with a message that names the fix.
    function test_EstablishDecimals_MismatchRefuses() public {
        vm.expectRevert(bytes("DECIMALS=8 disagrees with the token's own decimals()=6: fix or drop the variable"));
        this.establish(true, 6, 8);
    }

    function test_EstablishDecimals_OverflowRefusesInsteadOfTruncating() public {
        vm.expectRevert(bytes("DECIMALS must fit uint8 (0-255)"));
        this.establish(false, 0, 256);
    }

    /// @notice External for `expectRevert`: an internal library call would revert the test itself.
    function establish(bool okRead, uint8 read, uint256 supplied) external pure returns (uint8) {
        return DeploymentUtils._establishDecimals(okRead, read, supplied);
    }
}
