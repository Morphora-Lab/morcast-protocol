// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IMORCastEscrow} from "../src/interfaces/IMORCastEscrow.sol";
import {EscrowFixture} from "./utils/EscrowFixture.sol";
import {MerkleTreeBuilder} from "./utils/MerkleTreeBuilder.sol";

/// @notice Submits several claims in one transaction, as a gas-sponsoring relayer would.
contract ClaimBatcher {
    struct Claim {
        uint256 id;
        address wallet;
        uint256 amount;
        bytes32[] proof;
    }

    function claimAll(IMORCastEscrow escrow, Claim[] calldata claims) external {
        for (uint256 i; i < claims.length; i++) {
            escrow.claim(claims[i].id, claims[i].wallet, claims[i].amount, claims[i].proof);
        }
    }
}

/// @notice Attack scenarios from the internal security review (docs/security.md). Each test shows
///         that the attack fails, or that the documented behaviour holds.
contract SecurityTest is EscrowFixture {
    /// @notice A brand's standing approval cannot be spent by anyone else: `createCampaign`
    ///         always pulls from the caller, never from another account.
    function test_brandApprovalCannotBeSpentByOthers() public {
        // The fixture gives the brand an unlimited approval for the escrow.
        assertEq(usdc.allowance(brand, address(escrow)), type(uint256).max);
        uint256 brandBefore = usdc.balanceOf(brand);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, BUDGET
            )
        );
        vm.prank(stranger);
        escrow.createCampaign(address(usdc), BUDGET, TARGET, startAt, endAt, MANIFEST_HASH);

        assertEq(usdc.balanceOf(brand), brandBefore);
    }

    /// @notice Front-running a creator's claim neither redirects nor duplicates the payout: the
    ///         creator is paid once, the front-runner receives nothing, and the creator's own
    ///         transaction reverts harmlessly.
    function test_frontRunClaimPaysCreatorOnce() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _payouts();
        _settle(id, 640_000, _root(id, payouts));
        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), 0);

        vm.prank(stranger);
        escrow.claim(id, payouts[0].wallet, payouts[0].amount, proof);

        vm.expectRevert(IMORCastEscrow.AlreadyClaimed.selector);
        vm.prank(payouts[0].wallet);
        escrow.claim(id, payouts[0].wallet, payouts[0].amount, proof);

        assertEq(usdc.balanceOf(payouts[0].wallet), payouts[0].amount);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    /// @notice A relayer can batch many claims in one transaction: the reentrancy guard is
    ///         released after every call, so sequential claims from one contract succeed.
    function test_relayerCanBatchClaimsInOneTransaction() public {
        uint256 id = _createCampaign();
        Payout[] memory payouts = _payouts();
        _settle(id, 640_000, _root(id, payouts));

        ClaimBatcher.Claim[] memory claims = new ClaimBatcher.Claim[](payouts.length);
        for (uint256 i; i < payouts.length; i++) {
            claims[i] = ClaimBatcher.Claim(
                id,
                payouts[i].wallet,
                payouts[i].amount,
                MerkleTreeBuilder.proof(_leaves(id, payouts), i)
            );
        }
        new ClaimBatcher().claimAll(escrow, claims);

        for (uint256 i; i < payouts.length; i++) {
            assertEq(usdc.balanceOf(payouts[i].wallet), payouts[i].amount);
        }
        assertEq(escrow.getCampaign(id).creatorClaimed, escrow.getCampaign(id).pool);
    }

    /// @notice Tokens sent to the escrow outside `createCampaign` change nothing: deposits still
    ///         pass the exact-amount check, campaigns pay exactly their own amounts, and the stray
    ///         tokens stay in the contract (there is no function that can move them).
    function test_strayTokensDoNotAffectAccounting() public {
        usdc.mint(stranger, 777e6);
        vm.prank(stranger);
        usdc.transfer(address(escrow), 777e6);

        uint256 id = _createCampaign();
        vm.warp(_day(10));
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(usdc.balanceOf(address(escrow)), 777e6);
    }

    /// @notice At every moment after Day 5, exactly one of settlement and the full refund is
    ///         possible, so the settler can never settle a campaign the brand could already
    ///         reclaim, and the brand can never reclaim a campaign that is still settleable.
    function testFuzz_settlementAndRefundAreMutuallyExclusive(uint256 moment) public {
        uint256 id = _createCampaign();
        uint256 t = bound(moment, _day(5), _day(30));
        vm.warp(t);

        uint256 snapshot = vm.snapshotState();
        vm.prank(settler);
        bool settled = _succeeds(
            address(escrow), abi.encodeCall(escrow.settle, (id, 0, bytes32(0), RESULT_HASH))
        );
        vm.revertToState(snapshot);
        vm.prank(brand);
        bool refunded = _succeeds(address(escrow), abi.encodeCall(escrow.withdrawBrand, (id)));

        assertTrue(settled != refunded, "exactly one must be possible");
        assertEq(settled, t < _day(10));
    }

    /// @notice No sequence of payouts on a settled campaign can pay out more than its budget,
    ///         even if the settler's tree lists the same wallet twice with different amounts.
    function test_duplicateWalletLeavesAreStillCappedByPool() public {
        uint256 id = _createCampaign();
        address creator = makeAddr("creator");
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(creator, 51_200e6); // the whole pool
        payouts[1] = Payout(creator, 1e6); // an extra leaf for the same wallet
        _settle(id, 640_000, _root(id, payouts));

        _claim(id, payouts, 0, creator);
        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), 1);
        vm.expectRevert(abi.encodeWithSelector(IMORCastEscrow.PoolExceeded.selector, 1e6, 0));
        escrow.claim(id, creator, 1e6, proof);

        escrow.withdrawFee(id);
        vm.prank(brand);
        escrow.withdrawBrand(id);
        assertEq(usdc.balanceOf(address(escrow)), 0, "the campaign paid out exactly its budget");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @dev Creator payouts of the specification's partial-delivery example (pool 51,200 USDC).
    function _payouts() internal returns (Payout[] memory payouts) {
        payouts = new Payout[](4);
        payouts[0] = Payout(makeAddr("creator 1"), 24_000e6);
        payouts[1] = Payout(makeAddr("creator 2"), 14_400e6);
        payouts[2] = Payout(makeAddr("creator 3"), 9_600e6);
        payouts[3] = Payout(makeAddr("creator 4"), 3_200e6);
    }

    /// @dev Performs a call and reports whether it succeeded, without reverting.
    function _succeeds(address target, bytes memory data) internal returns (bool ok) {
        (ok,) = target.call(data);
    }
}
