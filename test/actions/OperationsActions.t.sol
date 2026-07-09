// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {CctActions} from "../../src/actions/CctActions.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork parity tests for the PR 1.2 rollout of the `operations/` write scripts (mint, fee-token
/// withdrawal). Deposit/withdraw round-trips live in `LockboxOps.t.sol`. Each op is exercised through its
/// `CctActions` builder and asserted via balance deltas.
contract OperationsActionsForkTest is BaseForkTest {
    address internal token;
    address internal pool;
    address internal owner;

    function setUp() public override {
        super.setUp();
        (token, pool) = deployTokenAndPoolFixture();
        owner = _scriptBroadcaster();
    }

    // ── Mint: balanceOf delta ──────────────────────────────────────────────────

    function test_Mint_ChangesBalanceOf() public {
        address receiver = address(0xBEEF);
        uint256 amount = 1_234e18;
        uint256 before = IERC20(token).balanceOf(receiver);

        _exec(owner, CctActions.mint(token, receiver, amount));

        assertEq(IERC20(token).balanceOf(receiver) - before, amount, "mint credited the receiver");
    }

    // ── Fee-token withdrawal: drains the pool's fee-token balance to the recipient ──

    function test_WithdrawFeeTokens_DrainsPoolToRecipient() public {
        // Mint fee tokens straight onto the pool to simulate accrued fees, then sweep them.
        uint256 fees = 500e18;
        _exec(owner, CctActions.mint(token, pool, fees));
        assertEq(IERC20(token).balanceOf(pool), fees, "pool holds accrued fees");

        address recipient = address(0xF00D);
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);

        address[] memory feeTokens = new address[](1);
        feeTokens[0] = token;
        _exec(owner, CctActions.withdrawFeeTokens(pool, feeTokens, recipient));

        assertEq(IERC20(token).balanceOf(pool), 0, "pool fee balance drained");
        assertEq(IERC20(token).balanceOf(recipient) - recipientBefore, fees, "recipient received the fees");
    }

    // ── Gate: only the owner/feeAdmin can withdraw fees ──────────────────────────

    function test_WithdrawFeeTokens_GatedToOwner() public {
        _exec(owner, CctActions.mint(token, pool, 1e18));
        address[] memory feeTokens = new address[](1);
        feeTokens[0] = token;
        CctActions.Call[] memory calls = CctActions.withdrawFeeTokens(pool, feeTokens, address(0xF00D));
        vm.prank(address(0xBAD));
        (bool ok,) = calls[0].target.call(calls[0].data);
        assertFalse(ok, "a stranger cannot withdraw fee tokens");
    }
}
