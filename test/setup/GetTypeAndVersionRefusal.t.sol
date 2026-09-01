// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GetTypeAndVersion} from "../../script/setup/GetTypeAndVersion.s.sol";
import {EmptyReturn, RealTypeAndVersion, WildOffset} from "../fixtures/ReturnDataShells.sol";

/// @notice Reporting the version is this primitive's whole purpose, so refusing is right - but it has
/// to refuse by NAME. The raw `abi.decode` this replaced passed its `require(success)` on an address
/// that ANSWERED undecodably, then died on the decode with no reason, which reads as a broken tool
/// rather than a wrong address.
contract GetTypeAndVersionRefusalTest is Test {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    GetTypeAndVersion internal getter;

    function setUp() public {
        vm.chainId(SEPOLIA_CHAIN_ID);
        getter = new GetTypeAndVersion();
    }

    function test_RealContract_IsRead() public {
        assertEq(
            getter.readVersionForTest(address(new RealTypeAndVersion())),
            "BurnMintTokenPool 1.5.1",
            "a contract that answers must be read verbatim"
        );
    }

    function test_AnswersUndecodably_RefusesByName() public {
        address shell = address(new EmptyReturn());
        vm.expectRevert(
            bytes(
                string.concat(
                    "Contract at ",
                    vm.toString(shell),
                    " does not implement ITypeAndVersion (no code, or typeAndVersion() did not answer)"
                )
            )
        );
        getter.readVersionForTest(shell);
    }

    function test_GarbageAnswer_RefusesByName() public {
        address garbage = address(new WildOffset());
        vm.expectRevert();
        getter.readVersionForTest(garbage);
    }

    function test_CodelessAddress_RefusesByName() public {
        vm.expectRevert();
        getter.readVersionForTest(address(0xdead));
    }
}
