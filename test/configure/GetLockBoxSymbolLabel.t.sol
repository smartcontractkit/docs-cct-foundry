// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GetLockBox} from "../../script/configure/GetLockBox.s.sol";
import {EmptyReturn, WildOffset} from "../fixtures/ReturnDataShells.sol";

contract NamedToken {
    function symbol() external pure returns (string memory) {
        return "WIDGET";
    }
}

contract EmptySymbolToken {
    function symbol() external pure returns (string memory) {
        return "";
    }
}

contract RevertingSymbolToken {
    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }
}

/// @notice The lock-box report labels its token with the symbol in parentheses. Three different
/// failures - the token does not answer, answers "", or answers undecodably - all mean the same thing
/// for a label, so all three print bare. The regression this pins is the middle one: branching on
/// "did the read succeed" rather than "is there anything to show" printed a token answering "" as
/// `0x... ()`, an empty pair of brackets that reads like a bug in the tool.
contract GetLockBoxSymbolLabelTest is Test {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    GetLockBox internal getter;

    function setUp() public {
        vm.chainId(SEPOLIA_CHAIN_ID);
        getter = new GetLockBox();
    }

    function test_NamedToken_IsParenthesised() public {
        assertEq(getter.symbolLabelForTest(address(new NamedToken())), " (WIDGET)", "a symbol is shown");
    }

    function test_TokenAnsweringEmpty_PrintsBare() public {
        assertEq(getter.symbolLabelForTest(address(new EmptySymbolToken())), "", "an empty symbol must not print ()");
    }

    function test_RevertingSymbol_PrintsBare() public {
        assertEq(getter.symbolLabelForTest(address(new RevertingSymbolToken())), "", "a reverting symbol prints bare");
    }

    /// The shapes that used to take the whole report down before `_readSymbol` was hardened.
    function test_UndecodableAndCodeless_PrintBare() public {
        assertEq(getter.symbolLabelForTest(address(new EmptyReturn())), "", "success with no data prints bare");
        assertEq(getter.symbolLabelForTest(address(new WildOffset())), "", "an undecodable answer prints bare");
        assertEq(getter.symbolLabelForTest(address(0xdead)), "", "a codeless address prints bare");
    }
}
