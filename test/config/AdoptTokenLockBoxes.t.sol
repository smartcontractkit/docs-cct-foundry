// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdoptToken} from "../../script/config/AdoptToken.s.sol";
import {MockSiloedPool} from "./VerifyChainSiloedLockBoxes.t.sol";

contract MockLockReleaseV2 {
    address public immutable box;

    constructor(address box_) {
        box = box_;
    }

    function getLockBox() external view returns (address) {
        return box;
    }
}

/// @notice adopt-token discovers the lock boxes of a 2.0 pool it did not deploy.
contract AdoptTokenLockBoxesTest is Test {
    AdoptToken internal adopt;

    function setUp() public {
        adopt = new AdoptToken();
    }

    function test_LockReleaseV2_SingleBox() public {
        MockLockReleaseV2 pool = new MockLockReleaseV2(address(0xB0B));
        (address[] memory boxes, uint64[] memory first) =
            adopt.lockBoxesOfForTest(address(pool), "LockReleaseTokenPool");
        assertEq(boxes.length, 1);
        assertEq(boxes[0], address(0xB0B));
        assertEq(first.length, 0, "a single box is the active one, not a silo");
    }

    function test_Siloed_DistinctBoxesWithFirstChain() public {
        MockSiloedPool pool = new MockSiloedPool("SiloedLockReleaseTokenPool 2.0.0", address(1));
        pool.mapBox(7, address(0xA));
        pool.mapBox(8, address(0xB));
        pool.mapBox(9, address(0xA));
        (address[] memory boxes, uint64[] memory first) =
            adopt.lockBoxesOfForTest(address(pool), "SiloedLockReleaseTokenPool");
        assertEq(boxes.length, 2, "shared box listed once");
        assertEq(boxes[0], address(0xA));
        assertEq(first[0], 7, "named after the first chain it serves");
        assertEq(boxes[1], address(0xB));
        assertEq(first[1], 8);
    }

    function test_OtherPoolTypes_NoBoxes() public {
        MockLockReleaseV2 pool = new MockLockReleaseV2(address(0xB0B));
        (address[] memory boxes,) = adopt.lockBoxesOfForTest(address(pool), "BurnMintTokenPool");
        assertEq(boxes.length, 0);
        (boxes,) = adopt.lockBoxesOfForTest(address(0xDEAD), "LockReleaseTokenPool");
        assertEq(boxes.length, 0, "a pool that does not answer yields nothing");
    }
}
