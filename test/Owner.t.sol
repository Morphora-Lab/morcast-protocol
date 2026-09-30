// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMORCastEscrow} from "../src/interfaces/IMORCastEscrow.sol";
import {EscrowFixture} from "./utils/EscrowFixture.sol";
import {MockERC20} from "./utils/Tokens.sol";

/// @notice Unit tests for the owner role: two-step ownership, settler and treasury replacement,
///         token allowlist, creation pause, voiding campaigns and recovering stray tokens.
///         Every test also checks that the owner cannot move a campaign's money anywhere except
///         back to its brand.
contract OwnerTest is EscrowFixture {
    address internal newOwner = makeAddr("new owner");
    address internal newSettler = makeAddr("new settler");
    address internal newTreasury = makeAddr("new treasury");

    // ===========================================================================================
    // Ownership
    // ===========================================================================================

    function test_ownership_transferNeedsAcceptance() public {
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), owner, "unchanged until accepted");
        assertEq(escrow.pendingOwner(), newOwner);

        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
        assertEq(escrow.pendingOwner(), address(0));
    }

    function test_ownership_onlyPendingOwnerCanAccept() public {
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        escrow.acceptOwnership();
    }

    /// @notice Nobody but the owner, including the settler and brands, can call owner actions.
    function test_ownerActions_revertForEveryoneElse() public {
        uint256 id = _createCampaign();
        address[3] memory others = [stranger, settler, brand];

        for (uint256 i; i < others.length; i++) {
            bytes memory unauthorized =
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]);
            vm.startPrank(others[i]);

            vm.expectRevert(unauthorized);
            escrow.setSettler(others[i]);
            vm.expectRevert(unauthorized);
            escrow.setTreasury(others[i]);
            vm.expectRevert(unauthorized);
            escrow.setCampaignToken(address(usdc), false);
            vm.expectRevert(unauthorized);
            escrow.setCreationPaused(true);
            vm.expectRevert(unauthorized);
            escrow.voidCampaign(id);
            vm.expectRevert(unauthorized);
            escrow.recoverTokens(address(usdc), others[i]);
            vm.expectRevert(unauthorized);
            escrow.transferOwnership(others[i]);

            vm.stopPrank();
        }
    }

    // ===========================================================================================
    // setSettler
    // ===========================================================================================

    function test_setSettler_replacesTheSettler() public {
        uint256 id = _createCampaign();

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.SettlerUpdated(settler, newSettler);
        vm.prank(owner);
        escrow.setSettler(newSettler);

        vm.warp(_day(5));
        vm.expectRevert(IMORCastEscrow.NotSettler.selector);
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);

        vm.prank(newSettler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);
        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Settled));
    }

    /// @notice With settlement disabled nobody can settle, and brands get their full budget
    ///         back from Day 10.
    function test_setSettler_zeroDisablesSettlement() public {
        uint256 id = _createCampaign();
        vm.prank(owner);
        escrow.setSettler(address(0));

        vm.warp(_day(5));
        vm.expectRevert(IMORCastEscrow.NotSettler.selector);
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);

        uint256 brandBefore = usdc.balanceOf(brand);
        vm.warp(_day(10));
        vm.prank(brand);
        escrow.withdrawBrand(id);
        assertEq(usdc.balanceOf(brand), brandBefore + BUDGET);
    }

    // ===========================================================================================
    // setTreasury
    // ===========================================================================================

    function test_setTreasury_redirectsFees() public {
        uint256 id = _createCampaign();
        _settle(id, TARGET, keccak256("root"));

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.TreasuryUpdated(treasury, newTreasury);
        vm.prank(owner);
        escrow.setTreasury(newTreasury);

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.FeeWithdrawn(id, newTreasury, 20_000e6);
        escrow.withdrawFee(id);

        assertEq(usdc.balanceOf(newTreasury), 20_000e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_setTreasury_revertsOnZeroAddress() public {
        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        vm.prank(owner);
        escrow.setTreasury(address(0));
    }

    // ===========================================================================================
    // setCreationPaused
    // ===========================================================================================

    /// @notice A pause blocks only new campaigns: existing campaigns can still be cancelled,
    ///         settled, claimed and refunded.
    function test_pause_blocksOnlyCampaignCreation() public {
        uint256 settledLater = _createCampaign();
        uint256 cancelledLater = _createCampaign();

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CreationPausedUpdated(true);
        vm.prank(owner);
        escrow.setCreationPaused(true);

        vm.expectRevert(IMORCastEscrow.CreationPaused.selector);
        _createCampaign();

        vm.prank(brand);
        escrow.cancel(cancelledLater);

        _settle(settledLater, 0, bytes32(0));
        escrow.withdrawFee(settledLater);
        vm.prank(brand);
        escrow.withdrawBrand(settledLater);

        vm.prank(owner);
        escrow.setCreationPaused(false);
        vm.warp(START_TIME); // back before startAt, so that a new campaign can be created
        assertEq(_createCampaign(), 3);
    }

    // ===========================================================================================
    // setCampaignToken
    // ===========================================================================================

    /// @notice Disallowing a token stops new campaigns in it; existing ones still pay out.
    function test_disallowedToken_blocksOnlyNewCampaigns() public {
        uint256 id = _createCampaign(address(mor), 100e18, TARGET);

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignTokenUpdated(address(mor), false);
        vm.prank(owner);
        escrow.setCampaignToken(address(mor), false);

        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnsupportedToken.selector, mor));
        _createCampaign(address(mor), 100e18, TARGET);

        // USDC is unaffected.
        _createCampaign();

        // The existing MOR campaign is refunded in full from Day 10.
        uint256 brandBefore = mor.balanceOf(brand);
        vm.warp(_day(10));
        vm.prank(brand);
        escrow.withdrawBrand(id);
        assertEq(mor.balanceOf(brand), brandBefore + 100e18);
    }

    function test_allowedToken_canBeUsedForNewCampaigns() public {
        MockERC20 usdt = new MockERC20("Tether USD", "USDT0", 6);
        _fund(brand, usdt, BUDGET);

        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.UnsupportedToken.selector, usdt));
        _createCampaign(address(usdt), BUDGET, TARGET);

        vm.prank(owner);
        escrow.setCampaignToken(address(usdt), true);
        uint256 id = _createCampaign(address(usdt), BUDGET, TARGET);

        assertEq(escrow.getCampaign(id).token, address(usdt));
        assertEq(escrow.totalOwed(address(usdt)), BUDGET);
    }

    function test_setCampaignToken_revertsOnZeroAddress() public {
        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        vm.prank(owner);
        escrow.setCampaignToken(address(0), true);
    }

    // ===========================================================================================
    // voidCampaign
    // ===========================================================================================

    /// @notice Voiding a running campaign returns the whole budget to its brand, and to no one
    ///         else, without waiting for the settlement window.
    function test_voidCampaign_returnsBudgetToBrand() public {
        uint256 id = _createCampaign();
        vm.warp(startAt + 3 days); // the campaign is running; the brand can no longer cancel
        uint256 brandBefore = usdc.balanceOf(brand);

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.CampaignVoided(id, brand, BUDGET);
        vm.prank(owner);
        escrow.voidCampaign(id);

        assertEq(usdc.balanceOf(brand), brandBefore + BUDGET);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Refunded));
        assertEq(escrow.totalOwed(address(usdc)), 0);
    }

    function test_voidCampaign_endsTheCampaign() public {
        uint256 id = _createCampaign();
        vm.prank(owner);
        escrow.voidCampaign(id);

        bytes memory refunded = abi.encodeWithSelector(
            IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Refunded
        );
        vm.warp(_day(5));
        vm.expectRevert(refunded);
        vm.prank(settler);
        escrow.settle(id, 0, bytes32(0), RESULT_HASH);

        vm.warp(_day(10));
        vm.expectRevert(refunded);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        vm.expectRevert(refunded);
        vm.prank(owner);
        escrow.voidCampaign(id);
    }

    /// @notice A settled campaign cannot be voided: its fee, pool and refund are already owed.
    function test_voidCampaign_revertsOnceSettled() public {
        uint256 id = _createCampaign();
        _settle(id, TARGET, keccak256("root"));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMORCastEscrow.InvalidStatus.selector, IMORCastEscrow.Status.Settled
            )
        );
        vm.prank(owner);
        escrow.voidCampaign(id);
    }

    // ===========================================================================================
    // recoverTokens
    // ===========================================================================================

    /// @notice Only tokens beyond what campaigns are owed can be recovered; every campaign can
    ///         still be paid in full afterwards.
    function test_recoverTokens_returnsOnlyStrayTokens() public {
        uint256 first = _createCampaign();
        uint256 second = _createCampaign();
        _sendToEscrow(usdc, 777e6);
        address recipient = makeAddr("sender of the stray tokens");

        vm.expectEmit(address(escrow));
        emit IMORCastEscrow.TokensRecovered(address(usdc), recipient, 777e6);
        vm.prank(owner);
        escrow.recoverTokens(address(usdc), recipient);
        assertEq(usdc.balanceOf(recipient), 777e6);

        // Both budgets are still there and are refunded in full.
        vm.warp(_day(10));
        vm.startPrank(brand);
        escrow.withdrawBrand(first);
        escrow.withdrawBrand(second);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @notice The owner cannot take campaign funds: with nothing stray, recovery reverts.
    function test_recoverTokens_cannotTouchCampaignFunds() public {
        _createCampaign();

        vm.expectRevert(IMORCastEscrow.NothingToRecover.selector);
        vm.prank(owner);
        escrow.recoverTokens(address(usdc), owner);

        assertEq(usdc.balanceOf(address(escrow)), BUDGET);
    }

    function test_recoverTokens_recoversTokensNoCampaignUses() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        _sendToEscrow(other, 5e18);

        vm.prank(owner);
        escrow.recoverTokens(address(other), stranger);
        assertEq(other.balanceOf(stranger), 5e18);
    }

    function test_recoverTokens_revertsOnZeroRecipient() public {
        _sendToEscrow(usdc, 1);
        vm.expectRevert(IMORCastEscrow.ZeroAddress.selector);
        vm.prank(owner);
        escrow.recoverTokens(address(usdc), address(0));
    }

    // ===========================================================================================
    // totalOwed
    // ===========================================================================================

    /// @notice `totalOwed` follows a campaign from deposit to the last payout.
    function test_totalOwed_followsTheLifecycle() public {
        uint256 id = _createCampaign();
        assertEq(escrow.totalOwed(address(usdc)), BUDGET);

        // Settlement changes who is owed what, not the total.
        address creator = makeAddr("creator");
        bytes32 leaf = escrow.leafHash(id, creator, 51_200e6);
        _settle(id, 640_000, leaf);
        assertEq(escrow.totalOwed(address(usdc)), BUDGET);

        escrow.claim(id, creator, 51_200e6, new bytes32[](0));
        assertEq(escrow.totalOwed(address(usdc)), BUDGET - 51_200e6);

        escrow.withdrawFee(id);
        assertEq(escrow.totalOwed(address(usdc)), 36_000e6);

        vm.prank(brand);
        escrow.withdrawBrand(id);
        assertEq(escrow.totalOwed(address(usdc)), 0);
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    /// @dev Transfers `amount` straight to the escrow, outside any campaign.
    function _sendToEscrow(MockERC20 token, uint256 amount) internal {
        token.mint(stranger, amount);
        vm.prank(stranger);
        token.transfer(address(escrow), amount);
    }
}
