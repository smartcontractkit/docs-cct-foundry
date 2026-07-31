// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeploymentUtils} from "../../script/utils/DeploymentUtils.s.sol";

/// @dev A token whose `symbol()` answers, but with the empty string. ERC20 marks the function optional,
///      and "optional" covers this shape as well as the missing one.
contract EmptySymbolToken {
    function symbol() external pure returns (string memory) {
        return "";
    }
}

/// @dev A token with no `symbol()` at all: the call reverts.
contract NoSymbolToken {}

contract NamedToken {
    function symbol() external pure returns (string memory) {
        return "WIDGET";
    }
}

/// @notice What `DeploymentUtils._trySymbol` accepts as a symbol, and what it refuses.
///
/// The registry keys entries on the symbol, so anything that two different tokens could both resolve to
/// must not count as one: the empty string and the literal "unknown" are what a failure looks like, and
/// accepting either lets a later failed read overwrite an earlier token's entry.
///
/// The decision is pinned through `_establishSymbol`, which takes the TOKEN_SYMBOL fallback as an
/// argument: `vm.setEnv` is process-wide while tests run in parallel, and DeployToken reads the same
/// variable, so these tests never touch the environment.
contract TokenSymbolResolutionTest is Test {
    /// @dev A revert and an empty answer must reach the decision as the same shape, so the fallback
    ///      covers both. If the fallback covered only the revert, a token answering "" would be told to
    ///      set TOKEN_SYMBOL and then have the value ignored.
    function test_ReadSymbol_RevertAndEmptyAnswerLookAlike() public {
        assertEq(DeploymentUtils._readSymbol(address(new NoSymbolToken())), "", "a reverting symbol() reads empty");
        assertEq(DeploymentUtils._readSymbol(address(new EmptySymbolToken())), "", "an empty answer reads empty");
        assertEq(DeploymentUtils._readSymbol(address(new NamedToken())), "WIDGET");
    }

    function test_EstablishSymbol_TokenAnswerWinsOverFallback() public pure {
        (bool ok, string memory symbol) = DeploymentUtils._establishSymbol("WIDGET", "FALLBACK");
        assertTrue(ok, "a non-empty symbol from the token is usable");
        assertEq(symbol, "WIDGET");
    }

    function test_EstablishSymbol_FallbackCoversAnEmptyRead() public pure {
        (bool ok, string memory symbol) = DeploymentUtils._establishSymbol("", "FALLBACK");
        assertTrue(ok, "TOKEN_SYMBOL covers a token that supplied nothing");
        assertEq(symbol, "FALLBACK");
    }

    function test_EstablishSymbol_FailureShapesCountFromNeitherSource() public pure {
        (bool okNothing,) = DeploymentUtils._establishSymbol("", "unknown");
        assertFalse(okNothing, "no answer and no fallback ends at the sentinel, which is no symbol");

        (bool okEmptyFallback, string memory symbol) = DeploymentUtils._establishSymbol("", "");
        assertFalse(okEmptyFallback, "an empty TOKEN_SYMBOL is no symbol");
        assertEq(symbol, "");

        (bool okSentinelFromToken,) = DeploymentUtils._establishSymbol("unknown", "FALLBACK");
        assertFalse(okSentinelFromToken, "a token whose symbol is the sentinel cannot key the registry");
    }

    /// @dev The composed read, on the one path that never consults the fallback.
    function test_TrySymbol_SymbolFromToken_IsAccepted() public {
        (bool ok, string memory symbol) = DeploymentUtils._trySymbol(vm, address(new NamedToken()));
        assertTrue(ok);
        assertEq(symbol, "WIDGET");
    }
}
