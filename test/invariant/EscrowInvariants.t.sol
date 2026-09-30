// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {MORCastEscrow} from "../../src/MORCastEscrow.sol";
import {IMORCastEscrow} from "../../src/interfaces/IMORCastEscrow.sol";
import {SettlementMath} from "../../src/libraries/SettlementMath.sol";
import {MockERC20} from "../utils/Tokens.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// @notice Global properties that must hold after every sequence of escrow actions.
/// @dev The fuzzer calls random handler actions (create, cancel, warp, settle, claim,
///      withdrawFee, withdrawBrand) across many campaigns in both tokens, and checks every
///      invariant below after each call.
contract EscrowInvariantsTest is StdInvariant, Test {
    MockERC20 internal usdc;
    MockERC20 internal mor;
    MORCastEscrow internal escrow;
    EscrowHandler internal handler;

    function setUp() public {
        vm.warp(1_767_225_600); // 2026-01-01T00:00:00Z

        usdc = new MockERC20("USD Coin", "USDC", 6);
        mor = new MockERC20("MorpheusAI", "MOR", 18);
        escrow = new MORCastEscrow(
            makeAddr("settler"), makeAddr("treasury"), address(usdc), address(mor)
        );
        handler = new EscrowHandler(escrow, usdc, mor, makeAddr("settler"));

        // Only the handler's actions are called; views and helpers are excluded.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = EscrowHandler.createCampaign.selector;
        selectors[1] = EscrowHandler.cancel.selector;
        selectors[2] = EscrowHandler.warp.selector;
        selectors[3] = EscrowHandler.settle.selector;
        selectors[4] = EscrowHandler.claim.selector;
        selectors[5] = EscrowHandler.withdrawFee.selector;
        selectors[6] = EscrowHandler.withdrawBrand.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The escrow's token balances equal the handler's independent bookkeeping of every
    ///         deposit and payout.
    function invariant_balancesMatchIndependentAccounting() public view {
        assertEq(usdc.balanceOf(address(escrow)), handler.ghostBalance(address(usdc)), "USDC");
        assertEq(mor.balanceOf(address(escrow)), handler.ghostBalance(address(mor)), "MOR");
    }

    /// @notice The escrow holds exactly what it still owes according to its own records:
    ///         funded budgets, unpaid fees, unpaid refunds and unclaimed creator pools.
    function invariant_balancesMatchOutstandingObligations() public view {
        uint256 owedUsdc;
        uint256 owedMor;

        for (uint256 id = 1; id <= escrow.campaignCount(); id++) {
            IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
            uint256 owed = _outstanding(c);
            if (c.token == address(usdc)) owedUsdc += owed;
            else owedMor += owed;
        }

        assertEq(usdc.balanceOf(address(escrow)), owedUsdc, "USDC");
        assertEq(mor.balanceOf(address(escrow)), owedMor, "MOR");
    }

    /// @notice Every settled campaign follows the settlement formula exactly, never pays out
    ///         more than its budget, and never pays creators more than the pool.
    function invariant_settledCampaignsFollowFormula() public view {
        for (uint256 id = 1; id <= escrow.campaignCount(); id++) {
            IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
            if (c.status != IMORCastEscrow.Status.Settled) continue;

            (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
                SettlementMath.split(c.budget, c.target, c.recognized);

            assertEq(c.spent, spent, "spent");
            assertEq(c.fee, fee, "fee");
            assertEq(c.pool, pool, "pool");
            assertEq(c.refund, refund, "refund");
            assertEq(c.fee + c.pool + c.refund, c.budget, "fee + pool + refund != budget");
            assertLe(c.creatorClaimed, c.pool, "claims exceed pool");
            if (c.recognized >= c.target) assertEq(c.spent, c.budget, "target reached");
            if (c.recognized == 0) assertEq(c.spent, 0, "nothing recognized");
        }
    }

    /// @notice Campaign IDs are sequential and every created campaign is recorded.
    function invariant_campaignCountMatches() public view {
        assertEq(escrow.campaignCount(), handler.campaignCount());
    }

    /// @dev What the escrow still owes for one campaign.
    function _outstanding(IMORCastEscrow.Campaign memory c) private pure returns (uint256) {
        if (c.status == IMORCastEscrow.Status.Funded) return c.budget;
        if (c.status != IMORCastEscrow.Status.Settled) return 0; // Cancelled or Refunded

        uint256 owed = c.pool - c.creatorClaimed;
        if (!c.feePaid) owed += c.fee;
        if (!c.refundPaid) owed += c.refund;
        return owed;
    }
}
