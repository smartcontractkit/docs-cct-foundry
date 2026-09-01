// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AcceptOwnership} from "../../script/setup/transfer-ownership/AcceptOwnership.s.sol";
import {TransferOwnership} from "../../script/setup/transfer-ownership/TransferOwnership.s.sol";
import {EmptyReturn, RealTypeAndVersion, WildOffset} from "../fixtures/ReturnDataShells.sol";

contract AcceptLabelHarness is AcceptOwnership {
    function label(address a) external view returns (string memory) {
        return _entityLabel(a);
    }
}

contract TransferLabelHarness is TransferOwnership {
    function label(address a) external view returns (string memory) {
        return _entityLabel(a);
    }
}

/// @notice The ownership scripts label their output with the target's `typeAndVersion()`, falling back
/// to "Contract". The label is decoration, and it ran BEFORE the authority checks - so against an
/// address that answers undecodably, a plain `try` ended the run at the cosmetic step, with no reason
/// string and before the script could tell the operator whose authority was wrong.
///
/// Both scripts carry the same helper, so both are driven here: a fix applied to one and not the other
/// is the failure this suite exists to catch.
contract OwnershipLabelToleranceTest is Test {
    AcceptLabelHarness internal acceptHarness;
    TransferLabelHarness internal transferHarness;

    function setUp() public {
        acceptHarness = new AcceptLabelHarness();
        transferHarness = new TransferLabelHarness();
    }

    function test_AnswersUndecodably_FallsBackInsteadOfReverting() public {
        address empty = address(new EmptyReturn());
        address wild = address(new WildOffset());
        assertEq(acceptHarness.label(empty), "Contract", "accept: success with no data falls back");
        assertEq(acceptHarness.label(wild), "Contract", "accept: an undecodable answer falls back");
        assertEq(transferHarness.label(empty), "Contract", "transfer: success with no data falls back");
        assertEq(transferHarness.label(wild), "Contract", "transfer: an undecodable answer falls back");
    }

    function test_RealAnswer_IsStillUsed() public {
        address real = address(new RealTypeAndVersion());
        assertEq(acceptHarness.label(real), "BurnMintTokenPool 1.5.1", "accept: a real answer still labels");
        assertEq(transferHarness.label(real), "BurnMintTokenPool 1.5.1", "transfer: a real answer still labels");
    }

    function test_CodelessAddress_FallsBack() public view {
        assertEq(acceptHarness.label(address(0xdead)), "Contract", "accept: no code falls back");
        assertEq(transferHarness.label(address(0xdead)), "Contract", "transfer: no code falls back");
    }
}
