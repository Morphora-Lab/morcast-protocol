// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {MORCastEscrow} from "../../src/MORCastEscrow.sol";
import {IMORCastEscrow} from "../../src/interfaces/IMORCastEscrow.sol";
import {SettlementMath} from "../../src/libraries/SettlementMath.sol";
import {MerkleTreeBuilder} from "../utils/MerkleTreeBuilder.sol";
import {PayoutAllocation} from "../utils/PayoutAllocation.sol";
import {MockERC20} from "../utils/Tokens.sol";

/// @notice Drives the escrow through random but valid sequences of actions for invariant tests.
/// @dev The fuzzer calls these functions with random arguments. Each function turns the random
///      input into a valid action (or does nothing if no valid action exists) and records what
///      the escrow should hold afterwards in `ghostBalance`, independently of the escrow's own
///      bookkeeping.
contract EscrowHandler is Test {
    MORCastEscrow public immutable escrow;
    MockERC20 public immutable usdc;
    MockERC20 public immutable mor;
    address public immutable settler;

    /// @notice Tokens the escrow should hold, per token, according to this handler.
    mapping(address token => uint256) public ghostBalance;

    /// @notice Number of successful calls per action, useful when debugging a failing run.
    mapping(string action => uint256) public calls;

    address[] internal _brands;
    address[] internal _creators;
    uint256[] internal _ids;

    /// @dev Payouts fixed at settlement: wallets, amounts, Merkle leaves and claim status.
    mapping(uint256 id => address[]) internal _payoutWallets;
    mapping(uint256 id => uint256[]) internal _payoutAmounts;
    mapping(uint256 id => bytes32[]) internal _payoutLeaves;
    mapping(uint256 id => mapping(uint256 index => bool)) internal _payoutClaimed;

    constructor(MORCastEscrow escrow_, MockERC20 usdc_, MockERC20 mor_, address settler_) {
        escrow = escrow_;
        usdc = usdc_;
        mor = mor_;
        settler = settler_;

        for (uint256 i; i < 3; i++) {
            _brands.push(makeAddr(string.concat("brand ", vm.toString(i))));
        }
        for (uint256 i; i < 5; i++) {
            _creators.push(makeAddr(string.concat("creator ", vm.toString(i))));
        }
    }

    function campaignCount() external view returns (uint256) {
        return _ids.length;
    }

    // -------------------------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------------------------

    /// @notice A random brand creates a campaign with random terms in USDC or MOR.
    function createCampaign(
        uint256 brandSeed,
        bool useMor,
        uint256 budget,
        uint256 target,
        uint256 startDelay,
        uint256 duration
    ) external {
        address brand = _brands[brandSeed % _brands.length];
        MockERC20 token = useMor ? mor : usdc;

        budget = bound(budget, 1, 1e30) * 5; // always a multiple of 5
        target = bound(target, 1, 1e18);
        uint64 startAt = uint64(block.timestamp + bound(startDelay, 1, 30 days));
        uint64 endAt = uint64(startAt + bound(duration, 1, 60 days));

        token.mint(brand, budget);
        vm.startPrank(brand);
        token.approve(address(escrow), budget);
        uint256 id = escrow.createCampaign(
            address(token), budget, target, startAt, endAt, keccak256(abi.encode(_ids.length))
        );
        vm.stopPrank();

        _ids.push(id);
        ghostBalance[address(token)] += budget;
        calls["createCampaign"]++;
    }

    /// @notice The brand cancels a campaign that has not started yet.
    function cancel(uint256 idSeed) external {
        (bool found, uint256 id) = _find(idSeed, _isCancellable);
        if (!found) return;
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);

        vm.prank(c.brand);
        escrow.cancel(id);

        ghostBalance[c.token] -= c.budget;
        calls["cancel"]++;
    }

    /// @notice Time moves forward by up to three days.
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 days));
        calls["warp"]++;
    }

    /// @notice The settler settles a funded campaign with random creator scores. If the window
    ///         has not opened yet, time first moves to a random point inside it.
    function settle(uint256 idSeed, uint256 creatorCount, uint256 scoreSeed, uint256 offsetSeed)
        external
    {
        (bool found, uint256 id) = _find(idSeed, _isSettleable);
        if (!found) return;
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);

        (uint256 opensAt, uint256 closesAt) = escrow.settlementWindow(id);
        if (block.timestamp < opensAt) {
            vm.warp(opensAt + bound(offsetSeed, 0, closesAt - opensAt - 1));
        }

        // Random scores for up to five creators. Zero creators means S = 0.
        uint256 n = bound(creatorCount, 0, _creators.length);
        address[] memory wallets = new address[](n);
        uint256[] memory scores = new uint256[](n);
        uint256 recognized;
        for (uint256 i; i < n; i++) {
            wallets[i] = _creators[i];
            scores[i] = bound(uint256(keccak256(abi.encode(scoreSeed, i))), 1, 2 * c.target);
            recognized += scores[i];
        }

        // Payouts follow the off-chain rule; only non-zero payouts become Merkle leaves.
        (,, uint256 pool,) = SettlementMath.split(c.budget, c.target, recognized);
        uint256[] memory amounts = PayoutAllocation.allocate(pool, wallets, scores);
        for (uint256 i; i < n; i++) {
            if (amounts[i] == 0) continue;
            _payoutWallets[id].push(wallets[i]);
            _payoutAmounts[id].push(amounts[i]);
            _payoutLeaves[id].push(escrow.leafHash(id, wallets[i], amounts[i]));
        }
        bytes32 root =
            _payoutLeaves[id].length == 0 ? bytes32(0) : MerkleTreeBuilder.root(_payoutLeaves[id]);

        vm.prank(settler);
        escrow.settle(id, recognized, root, keccak256(abi.encode("result", id)));
        calls["settle"]++;
    }

    /// @notice A random caller submits an unclaimed payout of a settled campaign.
    function claim(uint256 idSeed, uint256 indexSeed, uint256 callerSeed) external {
        (bool found, uint256 id) = _find(idSeed, _hasUnclaimedPayout);
        if (!found) return;

        // Pick the first unclaimed payout at or after the random index.
        uint256 count = _payoutWallets[id].length;
        uint256 index = indexSeed % count;
        while (_payoutClaimed[id][index]) {
            index = (index + 1) % count;
        }

        address wallet = _payoutWallets[id][index];
        uint256 amount = _payoutAmounts[id][index];
        bytes32[] memory proof = MerkleTreeBuilder.proof(_payoutLeaves[id], index);

        vm.prank(_creators[callerSeed % _creators.length]);
        escrow.claim(id, wallet, amount, proof);

        _payoutClaimed[id][index] = true;
        ghostBalance[escrow.getCampaign(id).token] -= amount;
        calls["claim"]++;
    }

    /// @notice Anyone sends the fee of a settled campaign to the treasury.
    function withdrawFee(uint256 idSeed) external {
        (bool found, uint256 id) = _find(idSeed, _hasUnpaidFee);
        if (!found) return;
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);

        escrow.withdrawFee(id);

        ghostBalance[c.token] -= c.fee;
        calls["withdrawFee"]++;
    }

    /// @notice The brand withdraws its refund, or the whole budget of an unsettled campaign
    ///         from Day 10.
    function withdrawBrand(uint256 idSeed) external {
        (bool found, uint256 id) = _find(idSeed, _isBrandWithdrawable);
        if (!found) return;
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);

        vm.prank(c.brand);
        escrow.withdrawBrand(id);

        ghostBalance[c.token] -= c.status == IMORCastEscrow.Status.Settled ? c.refund : c.budget;
        calls["withdrawBrand"]++;
    }

    // -------------------------------------------------------------------------------------------
    // Campaign selection
    // -------------------------------------------------------------------------------------------

    /// @dev Starting at a random campaign, returns the first one that satisfies `eligible`.
    function _find(uint256 seed, function(uint256) view returns (bool) eligible)
        internal
        view
        returns (bool found, uint256 id)
    {
        uint256 length = _ids.length;
        if (length == 0) return (false, 0);
        // Reduce the seed first: `seed + k` could overflow for seeds close to 2^256.
        uint256 start = seed % length;
        for (uint256 k; k < length; k++) {
            id = _ids[(start + k) % length];
            if (eligible(id)) return (true, id);
        }
        return (false, 0);
    }

    function _isCancellable(uint256 id) internal view returns (bool) {
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        return c.status == IMORCastEscrow.Status.Funded && block.timestamp < c.startAt;
    }

    function _isSettleable(uint256 id) internal view returns (bool) {
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        (, uint256 closesAt) = escrow.settlementWindow(id);
        return c.status == IMORCastEscrow.Status.Funded && block.timestamp < closesAt;
    }

    function _hasUnclaimedPayout(uint256 id) internal view returns (bool) {
        for (uint256 i; i < _payoutWallets[id].length; i++) {
            if (!_payoutClaimed[id][i]) return true;
        }
        return false;
    }

    function _hasUnpaidFee(uint256 id) internal view returns (bool) {
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        return c.status == IMORCastEscrow.Status.Settled && !c.feePaid;
    }

    function _isBrandWithdrawable(uint256 id) internal view returns (bool) {
        IMORCastEscrow.Campaign memory c = escrow.getCampaign(id);
        if (c.status == IMORCastEscrow.Status.Settled) return !c.refundPaid;
        if (c.status != IMORCastEscrow.Status.Funded) return false;
        (, uint256 closesAt) = escrow.settlementWindow(id);
        return block.timestamp >= closesAt;
    }
}
