// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MORCastEscrow} from "../src/MORCastEscrow.sol";
import {IMORCastEscrow} from "../src/interfaces/IMORCastEscrow.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";
import {EscrowFixture} from "./utils/EscrowFixture.sol";
import {MerkleTreeBuilder} from "./utils/MerkleTreeBuilder.sol";
import {FeeOnTransferToken, ReentrantToken} from "./utils/Tokens.sol";

/// @notice Unit tests for MORCastEscrow, grouped by function.
contract MORCastEscrowTest is EscrowFixture {
    // ===========================================================================================
    // constructor
    // ===========================================================================================

    function test_constructor_setsConfiguration() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.settler(), settler);
        assertEq(escrow.treasury(), treasury);
        assertTrue(escrow.isCampaignToken(address(usdc)));
        assertTrue(escrow.isCampaignToken(address(mor)));
        assertFalse(escrow.creationPaused());
        assertEq(escrow.SETTLEMENT_OPENS_AFTER(), 5 days);
        assertEq(escrow.SETTLEMENT_CLOSES_AFTER(), 10 days);
        assertEq(escrow.MAX_CAMPAIGN_DURATION(), 90 days);
        assertEq(escrow.campaignCount(), 0);
    }

    function test_constructor_emitsConfiguration() public {
        vm.expectEmit();
        emit IMORCastEscrow.SettlerUpdated(address(0), settler);
        vm.expectEmit();
        emit IMORCastEscrow.TreasuryUpdated(address(0), treasury);
        vm.expectEmit();
        emit IMORCastEscrow.CampaignTokenUpdated(address(usdc), true);
        new MORCastEscrow(owner, settler, treasury, _tokens(address(usdc)));
    }

    function test_constructor_revertsOnZeroAddress() public {
        address[] memory tokens = _tokens(address(usdc), address(mor));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MORCastEscrow(address(0), settler, treasury, tokens);

        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        new MORCastEscrow(owner, address(0), treasury, tokens);

        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        new MORCastEscrow(owner, settler, address(0), tokens);

        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        new MORCastEscrow(owner, settler, treasury, _tokens(address(usdc), address(0)));
    }

    // ===========================================================================================
    // createCampaign
    // ===========================================================================================

    function test_createCampaign_escrowsBudgetAndStoresTerms() public {
        uint256 brandBefore = usdc.balanceOf(brand);

        uint256 id = _createCampaign();

        assertEq(id, 1);
        assertEq(escrow.campaignCount(), 1);
        assertEq(usdc.balanceOf(address(escrow)), BUDGET);
        assertEq(usdc.balanceOf(brand), brandBefore - BUDGET);

        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        assertEq(c.brand, brand);
        assertEq(c.token, address(usdc));
        assertEq(c.budget, BUDGET);
        assertEq(c.target, TARGET);
        assertEq(c.startAt, startAt);
        assertEq(c.endAt, endAt);
        assertEq(c.manifestHash, MANIFEST_HASH);
        assertEq(uint8(c.status), uint8(IMORCastEscrow.Status.Funded));

        // Settlement fields stay empty until settlement.
        assertEq(c.recognized, 0);
        assertEq(c.spent, 0);
        assertEq(c.pool, 0);
        assertEq(c.merkleRoot, bytes32(0));
        assertEq(c.resultHash, bytes32(0));
        assertFalse(c.feePaid);
        assertFalse(c.refundPaid);
    }

    function test_createCampaign_acceptsMor() public {
        uint256 id = _createCampaign(address(mor), 500e18, TARGET);

        assertEq(escrow.getCampaign(id).token, address(mor));
        assertEq(mor.balanceOf(address(escrow)), 500e18);
    }

    function test_createCampaign_emitsEvent() public {
        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignCreated(
            1, brand, address(usdc), BUDGET, TARGET, startAt, endAt, MANIFEST_HASH
        );
        _createCampaign();
    }

    function test_createCampaign_assignsSequentialIds() public {
        assertEq(_createCampaign(), 1);
        assertEq(_createCampaign(), 2);
        assertEq(_createCampaign(address(mor), 5e18, 1), 3);
        assertEq(escrow.campaignCount(), 3);
    }

    function test_createCampaign_revertsOnUnsupportedToken() public {
        address other = makeAddr("other token");
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnsupportedToken.selector, other));
        vm.prank(brand);
        escrow.createCampaign(other, BUDGET, TARGET, startAt, endAt, MANIFEST_HASH);
    }

    function test_createCampaign_revertsOnZeroBudget() public {
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.InvalidBudget.selector, 0));
        _createCampaign(address(usdc), 0, TARGET);
    }

    function test_createCampaign_revertsOnBudgetNotMultipleOfFive() public {
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.InvalidBudget.selector, BUDGET + 1));
        _createCampaign(address(usdc), BUDGET + 1, TARGET);
    }

    function test_createCampaign_revertsOnZeroTarget() public {
        vm.expectRevert(IMORCastEscrow.InvalidTarget.selector);
        _createCampaign(address(usdc), BUDGET, 0);
    }

    function test_createCampaign_revertsOnEmptyWindow() public {
        // startAt == endAt
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.InvalidSchedule.selector, startAt, startAt)
        );
        vm.prank(brand);
        escrow.createCampaign(address(usdc), BUDGET, TARGET, startAt, startAt, MANIFEST_HASH);

        // startAt > endAt
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.InvalidSchedule.selector, endAt, startAt)
        );
        vm.prank(brand);
        escrow.createCampaign(address(usdc), BUDGET, TARGET, endAt, startAt, MANIFEST_HASH);
    }

    function test_createCampaign_acceptsMaximumDuration() public {
        uint64 lastEnd = startAt + 90 days;
        vm.prank(brand);
        uint256 id =
            escrow.createCampaign(address(usdc), BUDGET, TARGET, startAt, lastEnd, MANIFEST_HASH);
        assertEq(escrow.getCampaign(id).endAt, lastEnd);
    }

    function test_createCampaign_revertsWhenLongerThanMaximumDuration() public {
        uint64 tooLate = startAt + 90 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.InvalidSchedule.selector, startAt, tooLate)
        );
        vm.prank(brand);
        escrow.createCampaign(address(usdc), BUDGET, TARGET, startAt, tooLate, MANIFEST_HASH);
    }

    /// @notice An `endAt` given in milliseconds instead of seconds would lock the budget for
    ///         thousands of years after the start; the duration cap rejects it at creation.
    function test_createCampaign_rejectsEndAtInMilliseconds() public {
        uint64 endAtMillis = endAt * 1000;
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.InvalidSchedule.selector, startAt, endAtMillis)
        );
        vm.prank(brand);
        escrow.createCampaign(address(usdc), BUDGET, TARGET, startAt, endAtMillis, MANIFEST_HASH);
    }

    function test_createCampaign_revertsAtStart() public {
        // The deposit must be made strictly before startAt.
        vm.warp(startAt);
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.CampaignStarted.selector, startAt));
        _createCampaign();
    }

    function test_createCampaign_succeedsOneSecondBeforeStart() public {
        vm.warp(startAt - 1);
        assertEq(_createCampaign(), 1);
    }

    function test_createCampaign_revertsWithoutAllowance() public {
        vm.prank(brand);
        usdc.approve(address(escrow), BUDGET - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(escrow),
                BUDGET - 1,
                BUDGET
            )
        );
        _createCampaign();
    }

    function test_createCampaign_revertsWhenTokenDeliversLessThanBudget() public {
        // An escrow whose "USDC" charges 1% per transfer: the deposit check must reject it.
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        MORCastEscrow feeEscrow =
            new MORCastEscrow(owner, settler, treasury, _tokens(address(feeToken)));
        feeToken.mint(brand, BUDGET);
        vm.startPrank(brand);
        feeToken.approve(address(feeEscrow), BUDGET);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.DepositMismatch.selector, BUDGET, BUDGET - BUDGET / 100
            )
        );
        feeEscrow.createCampaign(address(feeToken), BUDGET, TARGET, startAt, endAt, MANIFEST_HASH);
        vm.stopPrank();
    }

    // ===========================================================================================
    // cancel
    // ===========================================================================================

    function test_cancel_returnsBudgetBeforeStart() public {
        uint256 id = _createCampaign();
        uint256 brandBefore = usdc.balanceOf(brand);

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignCancelled(id, brand, BUDGET);
        vm.prank(brand);
        escrow.cancel(id);

        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Cancelled));
        assertEq(usdc.balanceOf(brand), brandBefore + BUDGET);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_cancel_succeedsOneSecondBeforeStart() public {
        uint256 id = _createCampaign();
        vm.warp(startAt - 1);
        vm.prank(brand);
        escrow.cancel(id);
        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Cancelled));
    }

    function test_cancel_revertsAtStart() public {
        uint256 id = _createCampaign();
        vm.warp(startAt);
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.CampaignStarted.selector, startAt));
        vm.prank(brand);
        escrow.cancel(id);
    }

    function test_cancel_revertsForNonBrand() public {
        uint256 id = _createCampaign();
        vm.expectRevert(IMORCastEscrow.NotBrand.selector);
        vm.prank(stranger);
        escrow.cancel(id);
    }

    function test_cancel_revertsWhenAlreadyCancelled() public {
        uint256 id = _createCampaign();
        vm.startPrank(brand);
        escrow.cancel(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Cancelled
            )
        );
        escrow.cancel(id);
        vm.stopPrank();
    }

    function test_cancel_revertsForUnknownCampaign() public {
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnknownCampaign.selector, 7));
        vm.prank(brand);
        escrow.cancel(7);
    }

    // ===========================================================================================
    // settle
    // ===========================================================================================

    function test_settle_storesSplitFromRecognizedTotal() public {
        uint256 id = _createCampaign();
        bytes32 root = _root(id, _specPayouts());

        _settle(id, 640_000, root);

        // Specification example: S = 640,000 of T = 1,000,000 on a 100,000 USDC budget.
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        assertEq(uint8(c.status), uint8(IMORCastEscrow.Status.Settled));
        assertEq(c.recognized, 640_000);
        assertEq(c.spent, 64_000e6);
        assertEq(c.fee, 12_800e6);
        assertEq(c.pool, 51_200e6);
        assertEq(c.refund, 36_000e6);
        assertEq(c.merkleRoot, root);
        assertEq(c.resultHash, RESULT_HASH);
        assertEq(c.creatorClaimed, 0);
    }

    function test_settle_emitsEvent() public {
        uint256 id = _createCampaign();
        bytes32 root = _root(id, _specPayouts());
        vm.warp(_day(5));

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignSettled(
            id, 640_000, 64_000e6, 12_800e6, 51_200e6, 36_000e6, root, RESULT_HASH
        );
        vm.prank(settler);
        escrow.settle(id, 640_000, root, RESULT_HASH);
    }

    function test_settle_acceptsZeroRootWhenNothingRecognized() public {
        uint256 id = _createCampaign();
        _settle(id, 0, bytes32(0));

        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        assertEq(uint8(c.status), uint8(IMORCastEscrow.Status.Settled));
        assertEq(c.pool, 0);
        assertEq(c.refund, BUDGET);
    }

    function test_settle_opensExactlyAtDay5() public {
        uint256 id = _createCampaign();
        (uint256 opensAt, uint256 closesAt) = escrow.settlementWindow(id);

        vm.warp(_day(5) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.OutsideSettlementWindow.selector, opensAt, closesAt
            )
        );
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);

        vm.warp(_day(5));
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);
    }

    function test_settle_closesExactlyAtDay10() public {
        uint256 first = _createCampaign();
        uint256 second = _createCampaign();
        (uint256 opensAt, uint256 closesAt) = escrow.settlementWindow(first);

        // The last second of the window still works.
        vm.warp(_day(10) - 1);
        vm.prank(settler);
        escrow.settle(first, 0, bytes32(0), RESULT_HASH);

        // Day 10 itself is too late.
        vm.warp(_day(10));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.OutsideSettlementWindow.selector, opensAt, closesAt
            )
        );
        vm.prank(settler);
        escrow.settle(second, 0, bytes32(0), RESULT_HASH);
    }

    function test_settle_revertsForNonSettler() public {
        uint256 id = _createCampaign();
        vm.warp(_day(5));

        vm.expectRevert(IMORCastEscrow.NotSettler.selector);
        vm.prank(brand);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);

        vm.expectRevert(IMORCastEscrow.NotSettler.selector);
        vm.prank(treasury);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);
    }

    function test_settle_revertsWhenAlreadySettled() public {
        uint256 id = _createCampaign();
        _settle(id, 0, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Settled
            )
        );
        vm.prank(settler);
        escrow.settle(id, TARGET, keccak256("root"), RESULT_HASH);
    }

    function test_settle_revertsWhenCancelled() public {
        uint256 id = _createCampaign();
        vm.prank(brand);
        escrow.cancel(id);

        vm.warp(_day(5));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Cancelled
            )
        );
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);
    }

    function test_settle_revertsWithoutRootWhenPoolIsNotEmpty() public {
        uint256 id = _createCampaign();
        vm.warp(_day(5));
        vm.expectRevert(IMORCastEscrow.MissingMerkleRoot.selector);
        vm.prank(settler);
        escrow.settle(id, 640_000, bytes32(0), RESULT_HASH);
    }

    function test_settle_revertsWithoutResultHash() public {
        uint256 id = _createCampaign();
        vm.warp(_day(5));
        vm.expectRevert(IMORCastEscrow.MissingResultHash.selector);
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), bytes32(0));
    }

    function test_settle_revertsForUnknownCampaign() public {
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnknownCampaign.selector, 1));
        vm.prank(settler);
        escrow.settle(1, 0, bytes32(0), RESULT_HASH);
    }

    // ===========================================================================================
    // claim
    // ===========================================================================================

    function test_claim_paysWalletAndRecordsClaim() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        _settle(id, 640_000, _root(id, payouts));

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.Claimed(id, payouts[0].wallet, payouts[0].amount);
        _claim(id, payouts, 0, payouts[0].wallet);

        assertEq(usdc.balanceOf(payouts[0].wallet), 24_000e6);
        assertEq(escrow.getCampaign(id).creatorClaimed, 24_000e6);
        assertTrue(escrow.isClaimed(id, payouts[0].wallet, payouts[0].amount));
        assertTrue(escrow.claimed(escrow.leafHash(id, payouts[0].wallet, payouts[0].amount)));
        assertFalse(escrow.isClaimed(id, payouts[1].wallet, payouts[1].amount));
    }

    function test_claim_canBeSubmittedByAnyone() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        _settle(id, 640_000, _root(id, payouts));

        // A relayer submits the claim; the funds still go to the creator's wallet.
        _claim(id, payouts, 1, stranger);

        assertEq(usdc.balanceOf(payouts[1].wallet), 14_400e6);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_claim_allPayoutsExhaustPoolExactly() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        _settle(id, 640_000, _root(id, payouts));

        for (uint256 i; i < payouts.length; i++) {
            _claim(id, payouts, i, stranger);
            assertEq(usdc.balanceOf(payouts[i].wallet), payouts[i].amount);
        }

        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        assertEq(c.creatorClaimed, c.pool);
    }

    function test_claim_worksWithSingleLeafTree() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = new Payout[](1);
        payouts[0] = Payout(makeAddr("solo creator"), 80_000e6);

        // S >= T: the whole pool (80% of the budget) goes to the only creator.
        _settle(id, TARGET, _root(id, payouts));
        _claim(id, payouts, 0, payouts[0].wallet);

        assertEq(usdc.balanceOf(payouts[0].wallet), 80_000e6);
    }

    function test_claim_revertsOnSecondClaim() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        _settle(id, 640_000, _root(id, payouts));
        _claim(id, payouts, 2, stranger);

        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), 2);
        vm.expectRevert(IMORCastEscrow.AlreadyClaimed.selector);
        escrow.claim(id, payouts[2].wallet, payouts[2].amount, proof);
    }

    function test_claim_revertsOnWrongAmountOrWallet() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        _settle(id, 640_000, _root(id, payouts));
        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), 0);

        vm.expectRevert(IMORCastEscrow.InvalidProof.selector);
        escrow.claim(id, payouts[0].wallet, payouts[0].amount + 1, proof);

        vm.expectRevert(IMORCastEscrow.InvalidProof.selector);
        escrow.claim(id, stranger, payouts[0].amount, proof);
    }

    function test_claim_revertsWithLeafOfAnotherCampaign() public {
        // Two campaigns settled with the same root: the campaign ID inside the leaf still
        // prevents a proof for one campaign from paying out of the other.
        uint256 first = _createCampaign();
        uint256 second = _createCampaign();
        Payout[] memory payouts = _specPayouts();
        bytes32 root = _root(first, payouts);

        vm.warp(_day(5));
        vm.startPrank(settler);
        escrow.settle(first, 640_000, root, RESULT_HASH);
        escrow.settle(second, 640_000, root, RESULT_HASH);
        vm.stopPrank();

        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(first, payouts), 0);
        vm.expectRevert(IMORCastEscrow.InvalidProof.selector);
        escrow.claim(second, payouts[0].wallet, payouts[0].amount, proof);
    }

    function test_claim_revertsBeforeSettlement() public {
        uint256 id = _createCampaign();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Funded
            )
        );
        escrow.claim(id, stranger, 1, new bytes32[](0));
    }

    function test_claim_neverExceedsPool() public {
        // A faulty tree whose payouts add up to more than the pool: the last claim that would
        // exceed the pool is rejected.
        uint256 id = _createCampaign();
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(makeAddr("creator A"), 40_000e6);
        payouts[1] = Payout(makeAddr("creator B"), 40_000e6);
        _settle(id, 640_000, _root(id, payouts)); // pool = 51,200 USDC

        _claim(id, payouts, 0, stranger);

        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.PoolExceeded.selector, 40_000e6, 11_200e6)
        );
        escrow.claim(id, payouts[1].wallet, payouts[1].amount, proof);
    }

    // ===========================================================================================
    // withdrawFee
    // ===========================================================================================

    function test_withdrawFee_paysTreasury() public {
        uint256 id = _createCampaign();
        _settle(id, 640_000, _root(id, _specPayouts()));

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.FeeWithdrawn(id, treasury, 12_800e6);
        vm.prank(stranger); // anyone may trigger it
        escrow.withdrawFee(id);

        assertEq(usdc.balanceOf(treasury), 12_800e6);
        assertTrue(escrow.getCampaign(id).feePaid);
    }

    function test_withdrawFee_revertsOnSecondWithdrawal() public {
        uint256 id = _createCampaign();
        _settle(id, 640_000, _root(id, _specPayouts()));
        escrow.withdrawFee(id);

        vm.expectRevert(IMORCastEscrow.AlreadyWithdrawn.selector);
        escrow.withdrawFee(id);
    }

    function test_withdrawFee_marksZeroFeeAsPaid() public {
        uint256 id = _createCampaign();
        _settle(id, 0, bytes32(0));

        escrow.withdrawFee(id);

        assertTrue(escrow.getCampaign(id).feePaid);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_withdrawFee_revertsBeforeSettlement() public {
        uint256 id = _createCampaign();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Funded
            )
        );
        escrow.withdrawFee(id);
    }

    // ===========================================================================================
    // withdrawBrand
    // ===========================================================================================

    function test_withdrawBrand_paysRefundAfterSettlement() public {
        uint256 id = _createCampaign();
        _settle(id, 640_000, _root(id, _specPayouts()));
        uint256 brandBefore = usdc.balanceOf(brand);

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.RefundWithdrawn(id, brand, 36_000e6);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(usdc.balanceOf(brand), brandBefore + 36_000e6);
        assertTrue(escrow.getCampaign(id).refundPaid);
        // The campaign stays settled; creators can still claim.
        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Settled));
    }

    function test_withdrawBrand_revertsOnSecondRefund() public {
        uint256 id = _createCampaign();
        _settle(id, 640_000, _root(id, _specPayouts()));
        vm.startPrank(brand);
        escrow.withdrawBrand(id);

        vm.expectRevert(IMORCastEscrow.AlreadyWithdrawn.selector);
        escrow.withdrawBrand(id);
        vm.stopPrank();
    }

    function test_withdrawBrand_marksZeroRefundAsPaid() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = new Payout[](1);
        payouts[0] = Payout(makeAddr("solo creator"), 80_000e6);
        _settle(id, TARGET, _root(id, payouts)); // target reached: refund = 0

        uint256 brandBefore = usdc.balanceOf(brand);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertTrue(escrow.getCampaign(id).refundPaid);
        assertEq(usdc.balanceOf(brand), brandBefore);
    }

    function test_withdrawBrand_returnsBudgetFromDay10WhenNotSettled() public {
        uint256 id = _createCampaign();
        uint256 brandBefore = usdc.balanceOf(brand);

        vm.warp(_day(10));
        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignRefunded(id, brand, BUDGET);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(brand), brandBefore + BUDGET);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_withdrawBrand_revertsBeforeDay10WhenNotSettled() public {
        uint256 id = _createCampaign();
        vm.warp(_day(10) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IMORCastEscrow.RefundNotAvailable.selector, _day(10))
        );
        vm.prank(brand);
        escrow.withdrawBrand(id);
    }

    function test_withdrawBrand_blocksLaterSettlement() public {
        uint256 id = _createCampaign();
        vm.warp(_day(10));
        vm.prank(brand);
        escrow.withdrawBrand(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Refunded
            )
        );
        vm.prank(brand);
        escrow.withdrawBrand(id);
    }

    function test_withdrawBrand_revertsForNonBrand() public {
        uint256 id = _createCampaign();
        _settle(id, 640_000, _root(id, _specPayouts()));
        vm.expectRevert(IMORCastEscrow.NotBrand.selector);
        vm.prank(stranger);
        escrow.withdrawBrand(id);
    }

    function test_withdrawBrand_revertsWhenCancelled() public {
        uint256 id = _createCampaign();
        vm.startPrank(brand);
        escrow.cancel(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Cancelled
            )
        );
        escrow.withdrawBrand(id);
        vm.stopPrank();
    }

    // ===========================================================================================
    // Full lifecycle and isolation
    // ===========================================================================================

    /// @notice The specification's partial-delivery example end to end: every party receives
    ///         exactly its share and the escrow ends empty.
    function test_lifecycle_paysEveryPartyExactly() public {
        uint256 id = _createCampaign();
        uint256 brandBefore = usdc.balanceOf(brand);
        Payout[] memory payouts = _specPayouts();

        _settle(id, 640_000, _root(id, payouts));
        for (uint256 i; i < payouts.length; i++) {
            _claim(id, payouts, i, payouts[i].wallet);
        }
        escrow.withdrawFee(id);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(usdc.balanceOf(treasury), 12_800e6);
        assertEq(usdc.balanceOf(brand), brandBefore + 36_000e6);
        assertEq(usdc.balanceOf(payouts[0].wallet), 24_000e6);
        assertEq(usdc.balanceOf(payouts[1].wallet), 14_400e6);
        assertEq(usdc.balanceOf(payouts[2].wallet), 9_600e6);
        assertEq(usdc.balanceOf(payouts[3].wallet), 3_200e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @notice Settling and paying out one campaign leaves another campaign's budget untouched.
    function test_campaignsAreIsolated() public {
        uint256 first = _createCampaign();
        uint256 second = _createCampaign();
        Payout[] memory payouts = new Payout[](1);
        payouts[0] = Payout(makeAddr("creator"), 80_000e6);

        _settle(first, TARGET, _root(first, payouts));
        _claim(first, payouts, 0, stranger);
        escrow.withdrawFee(first);

        // Only the second campaign's budget remains, and it is still fully refundable.
        assertEq(usdc.balanceOf(address(escrow)), BUDGET);
        vm.warp(_day(10));
        vm.prank(brand);
        escrow.withdrawBrand(second);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @notice A token that calls back into the escrow during a payout is stopped by the
    ///         reentrancy guard, and the whole claim reverts.
    function test_reentrancyGuard_blocksCallbackFromToken() public {
        ReentrantToken token = new ReentrantToken();
        MORCastEscrow guarded = new MORCastEscrow(owner, settler, treasury, _tokens(address(token)));
        token.mint(brand, BUDGET);
        vm.startPrank(brand);
        token.approve(address(guarded), BUDGET);
        uint256 id =
            guarded.createCampaign(address(token), BUDGET, TARGET, startAt, endAt, MANIFEST_HASH);
        vm.stopPrank();

        address creator = makeAddr("creator");
        bytes32 leaf = guarded.leafHash(id, creator, 80_000e6);
        vm.warp(_day(5));
        vm.prank(settler);
        guarded.settle(id, TARGET, leaf, RESULT_HASH);

        // During the claim transfer, the token tries to call withdrawFee on the escrow.
        token.arm(address(guarded), abi.encodeCall(guarded.withdrawFee, (id)));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        guarded.claim(id, creator, 80_000e6, new bytes32[](0));
    }

    // ===========================================================================================
    // Views
    // ===========================================================================================

    function test_getCampaign_returnsEmptyForUnknownId() public view {
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(42);
        assertEq(uint8(c.status), uint8(IMORCastEscrow.Status.None));
        assertEq(c.brand, address(0));
    }

    function test_settlementWindow_isDay5ToDay10() public {
        uint256 id = _createCampaign();
        (uint256 opensAt, uint256 closesAt) = escrow.settlementWindow(id);
        assertEq(opensAt, uint256(endAt) + 5 days);
        assertEq(closesAt, uint256(endAt) + 10 days);
    }

    function test_settlementWindow_revertsForUnknownCampaign() public {
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnknownCampaign.selector, 1));
        escrow.settlementWindow(1);
    }

    function test_leafHash_usesStandardMerkleTreeEncoding() public view {
        address wallet = address(0xA11CE);
        bytes32 expected = keccak256(bytes.concat(keccak256(abi.encode(uint256(3), wallet, 99))));
        assertEq(escrow.leafHash(3, wallet, 99), expected);
    }

    function testFuzz_computeSplit_matchesLibrary(
        uint256 budget,
        uint256 target,
        uint256 recognized
    ) public view {
        target = bound(target, 1, type(uint256).max);
        (uint256 a, uint256 b, uint256 c, uint256 d) =
            escrow.computeSplit(budget, target, recognized);
        (uint256 e, uint256 f, uint256 g, uint256 h) =
            SettlementMath.split(budget, target, recognized);
        assertEq(a, e);
        assertEq(b, f);
        assertEq(c, g);
        assertEq(d, h);
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    /// @dev Creator payouts of the specification's partial-delivery example (pool 51,200 USDC).
    function _specPayouts() internal returns (Payout[] memory payouts) {
        payouts = new Payout[](4);
        payouts[0] = Payout(makeAddr("creator 1"), 24_000e6);
        payouts[1] = Payout(makeAddr("creator 2"), 14_400e6);
        payouts[2] = Payout(makeAddr("creator 3"), 9_600e6);
        payouts[3] = Payout(makeAddr("creator 4"), 3_200e6);
    }
}
