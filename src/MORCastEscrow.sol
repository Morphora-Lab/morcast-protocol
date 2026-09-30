// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMORCastEscrow} from "./interfaces/IMORCastEscrow.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";

/// @title MORCastEscrow
/// @notice Escrow for MORCast creator campaigns.
///
///         A brand escrows a budget in USDC or MOR. After the campaign, MORCast measures and
///         verifies performance off-chain, publishes the result dataset and settles the campaign
///         once with the recognized total S. The contract derives the fee, the creator pool and
///         the brand refund from S with a fixed formula, pays creators against a Merkle root,
///         and returns the whole budget to the brand if MORCast does not settle in time.
///
/// @dev Design rules:
///        - The contract holds money, pays it out once according to the fixed formula, and
///          refunds the brand if the campaign is not settled. Everything else happens off-chain.
///        - Nothing can be changed after deployment: no owner, no pause, no upgrade. The settler's
///          only power is `settle`, once per campaign, inside the settlement window.
///        - Every campaign has its own accounting. A campaign never pays out more than its own
///          budget, whatever happens to other campaigns.
///        - State is updated and events are emitted before every token transfer, transfers use
///          SafeERC20, and every function that moves tokens is also protected by a reentrancy
///          guard.
///        - Settlement is final and entitlements never expire.
contract MORCastEscrow is IMORCastEscrow, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------
    // Constants and immutables
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    /// @dev Day 5: results are published by Day 4 and reviewed until at least Day 5.
    uint256 public constant SETTLEMENT_OPENS_AFTER = 5 days;

    /// @inheritdoc IMORCastEscrow
    /// @dev Day 10: settlement is no longer possible and the brand may take the budget back.
    uint256 public constant SETTLEMENT_CLOSES_AFTER = 10 days;

    /// @inheritdoc IMORCastEscrow
    address public immutable SETTLER;

    /// @inheritdoc IMORCastEscrow
    address public immutable TREASURY;

    /// @inheritdoc IMORCastEscrow
    address public immutable USDC;

    /// @inheritdoc IMORCastEscrow
    address public immutable MOR;

    // -------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    uint256 public campaignCount;

    /// @dev Campaign ID => campaign. IDs start at 1, so ID 0 never exists.
    mapping(uint256 id => Campaign) private _campaigns;

    /// @inheritdoc IMORCastEscrow
    /// @dev Keyed by leaf hash. The leaf includes the campaign ID, so one global mapping is
    ///      enough to track claims of all campaigns.
    mapping(bytes32 leaf => bool) public claimed;

    // -------------------------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------------------------

    /// @param settler  The only address allowed to settle campaigns.
    /// @param treasury The address that receives protocol fees.
    /// @param usdc     The USDC token (on Base: Circle-issued USDC, 6 decimals).
    /// @param mor      The MOR token (on Base: Morpheus MOR, 18 decimals).
    constructor(address settler, address treasury, address usdc, address mor) {
        if (settler == address(0) || treasury == address(0)) revert ZeroAddress();
        if (usdc == address(0) || mor == address(0)) revert ZeroAddress();
        if (usdc == mor) revert IdenticalTokens();

        SETTLER = settler;
        TREASURY = treasury;
        USDC = usdc;
        MOR = mor;
    }

    // -------------------------------------------------------------------------------------------
    // Brand: create and cancel
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    function createCampaign(
        address token,
        uint256 budget,
        uint256 target,
        uint64 startAt,
        uint64 endAt,
        bytes32 manifestHash
    ) external nonReentrant returns (uint256 id) {
        // Only the two campaign tokens are accepted.
        if (token != USDC && token != MOR) revert UnsupportedToken(token);

        // A multiple of 5 guarantees that a fully spent budget splits exactly into 20% / 80%.
        if (budget == 0 || budget % SettlementMath.FEE_DIVISOR != 0) revert InvalidBudget(budget);

        // The target is the divisor of the settlement formula, so it must be positive.
        if (target == 0) revert InvalidTarget();

        // The campaign window [startAt, endAt) must not be empty.
        if (startAt >= endAt) revert InvalidSchedule(startAt, endAt);

        // The deposit must be made before the campaign starts.
        if (block.timestamp >= startAt) revert CampaignStarted(startAt);

        // Record the campaign before moving any tokens. The caller is the brand.
        id = ++campaignCount;
        Campaign storage campaign = _campaigns[id];
        campaign.brand = msg.sender;
        campaign.token = token;
        campaign.budget = budget;
        campaign.target = target;
        campaign.startAt = startAt;
        campaign.endAt = endAt;
        campaign.manifestHash = manifestHash;
        campaign.status = Status.Funded;

        emit CampaignCreated(id, msg.sender, token, budget, target, startAt, endAt, manifestHash);

        // Pull the budget and check that the escrow received exactly `budget`. This rejects any
        // token behaviour (such as a transfer fee) that would leave the campaign underfunded.
        // If the check fails, the whole transaction reverts, including the event above.
        IERC20 erc20 = IERC20(token);
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), budget);
        uint256 received = erc20.balanceOf(address(this)) - balanceBefore;
        if (received != budget) revert DepositMismatch(budget, received);
    }

    /// @inheritdoc IMORCastEscrow
    function cancel(uint256 id) external nonReentrant {
        Campaign storage campaign = _load(id);

        if (msg.sender != campaign.brand) revert NotBrand();
        if (campaign.status != Status.Funded) revert InvalidStatus(campaign.status);

        // After the start, creators may already be working on the campaign, so the budget stays
        // escrowed until settlement or the Day-10 refund.
        if (block.timestamp >= campaign.startAt) revert CampaignStarted(campaign.startAt);

        // Update state and emit the event first, then transfer.
        campaign.status = Status.Cancelled;
        uint256 amount = campaign.budget;
        emit CampaignCancelled(id, msg.sender, amount);

        IERC20(campaign.token).safeTransfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Settler: settle
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    function settle(uint256 id, uint256 recognized, bytes32 merkleRoot, bytes32 resultHash)
        external
    {
        if (msg.sender != SETTLER) revert NotSettler();

        Campaign storage campaign = _load(id);

        // Only a funded campaign can be settled, which also makes settlement happen at most once.
        if (campaign.status != Status.Funded) revert InvalidStatus(campaign.status);

        // Settlement is allowed only in [Day 5, Day 10).
        (uint256 opensAt, uint256 closesAt) = _settlementWindow(campaign.endAt);
        if (block.timestamp < opensAt || block.timestamp >= closesAt) {
            revert OutsideSettlementWindow(opensAt, closesAt);
        }

        // The split is computed here from S; the settler cannot choose the amounts directly.
        (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
            SettlementMath.split(campaign.budget, campaign.target, recognized);

        // A non-empty pool with a zero root could never be claimed and would be locked forever.
        if (pool != 0 && merkleRoot == bytes32(0)) revert MissingMerkleRoot();

        // Every settlement refers to a published result dataset, even when nothing is paid.
        if (resultHash == bytes32(0)) revert MissingResultHash();

        campaign.status = Status.Settled;
        campaign.recognized = recognized;
        campaign.spent = spent;
        campaign.fee = fee;
        campaign.pool = pool;
        campaign.refund = refund;
        campaign.merkleRoot = merkleRoot;
        campaign.resultHash = resultHash;

        // SettlementMath is an internal library call (a jump, not an external call), so no
        // external code runs before this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CampaignSettled(id, recognized, spent, fee, pool, refund, merkleRoot, resultHash);
    }

    // -------------------------------------------------------------------------------------------
    // After settlement: claim, fee, refund
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    function claim(uint256 id, address wallet, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Campaign storage campaign = _load(id);
        if (campaign.status != Status.Settled) revert InvalidStatus(campaign.status);

        // Each (campaign, wallet, amount) leaf can be claimed once.
        bytes32 leaf = _leafHash(id, wallet, amount);
        if (claimed[leaf]) revert AlreadyClaimed();

        // The leaf must be part of the tree whose root was fixed at settlement.
        if (!MerkleProof.verifyCalldata(proof, campaign.merkleRoot, leaf)) revert InvalidProof();

        // Defence in depth: even a wrong tree can never pay out more than the creator pool.
        uint256 remaining = campaign.pool - campaign.creatorClaimed;
        if (amount > remaining) revert PoolExceeded(amount, remaining);

        // Update state and emit the event first, then transfer. The funds go to the leaf's
        // wallet, never to the caller, so anyone (for example a gas-sponsoring relayer) can
        // submit the claim.
        claimed[leaf] = true;
        campaign.creatorClaimed += amount;
        // MerkleProof is an internal library call (a jump, not an external call), so no external
        // code runs before this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(id, wallet, amount);

        IERC20(campaign.token).safeTransfer(wallet, amount);
    }

    /// @inheritdoc IMORCastEscrow
    function withdrawFee(uint256 id) external nonReentrant {
        Campaign storage campaign = _load(id);
        if (campaign.status != Status.Settled) revert InvalidStatus(campaign.status);
        if (campaign.feePaid) revert AlreadyWithdrawn();

        campaign.feePaid = true;
        uint256 fee = campaign.fee;
        emit FeeWithdrawn(id, TREASURY, fee);

        // A zero fee (nothing recognized) is marked as paid without a transfer.
        if (fee != 0) IERC20(campaign.token).safeTransfer(TREASURY, fee);
    }

    /// @inheritdoc IMORCastEscrow
    function withdrawBrand(uint256 id) external nonReentrant {
        Campaign storage campaign = _load(id);
        if (msg.sender != campaign.brand) revert NotBrand();

        Status status = campaign.status;

        if (status == Status.Settled) {
            // Case 1: the campaign was settled. The brand receives B − G, once.
            if (campaign.refundPaid) revert AlreadyWithdrawn();

            campaign.refundPaid = true;
            uint256 refund = campaign.refund;
            emit RefundWithdrawn(id, msg.sender, refund);

            // A zero refund (target reached) is marked as paid without a transfer.
            if (refund != 0) IERC20(campaign.token).safeTransfer(msg.sender, refund);
        } else if (status == Status.Funded) {
            // Case 2: the campaign was never settled. From Day 10 the brand receives the whole
            // budget, and the campaign can no longer be settled.
            (, uint256 closesAt) = _settlementWindow(campaign.endAt);
            if (block.timestamp < closesAt) revert RefundNotAvailable(closesAt);

            campaign.status = Status.Refunded;
            uint256 budget = campaign.budget;
            emit CampaignRefunded(id, msg.sender, budget);

            IERC20(campaign.token).safeTransfer(msg.sender, budget);
        } else {
            // Cancelled and Refunded campaigns have nothing left to withdraw.
            revert InvalidStatus(status);
        }
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMORCastEscrow
    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return _campaigns[id];
    }

    /// @inheritdoc IMORCastEscrow
    function isClaimed(uint256 id, address wallet, uint256 amount) external view returns (bool) {
        return claimed[_leafHash(id, wallet, amount)];
    }

    /// @inheritdoc IMORCastEscrow
    function settlementWindow(uint256 id)
        external
        view
        returns (uint256 opensAt, uint256 closesAt)
    {
        return _settlementWindow(_load(id).endAt);
    }

    /// @inheritdoc IMORCastEscrow
    function leafHash(uint256 id, address wallet, uint256 amount) external pure returns (bytes32) {
        return _leafHash(id, wallet, amount);
    }

    /// @inheritdoc IMORCastEscrow
    function computeSplit(uint256 budget, uint256 target, uint256 recognized)
        external
        pure
        returns (uint256 spent, uint256 fee, uint256 pool, uint256 refund)
    {
        return SettlementMath.split(budget, target, recognized);
    }

    // -------------------------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------------------------

    /// @dev Returns the stored campaign, or reverts if it does not exist.
    function _load(uint256 id) private view returns (Campaign storage campaign) {
        campaign = _campaigns[id];
        if (campaign.status == Status.None) revert UnknownCampaign(id);
    }

    /// @dev Settlement window [Day 5, Day 10) of a campaign ending at `endAt`. Computed in
    ///      uint256, so it cannot overflow for any uint64 `endAt`.
    function _settlementWindow(uint64 endAt)
        private
        pure
        returns (uint256 opensAt, uint256 closesAt)
    {
        opensAt = uint256(endAt) + SETTLEMENT_OPENS_AFTER;
        closesAt = uint256(endAt) + SETTLEMENT_CLOSES_AFTER;
    }

    /// @dev Merkle leaf of a creator payout, in the OpenZeppelin StandardMerkleTree format for
    ///      the value types (uint256, address, uint256):
    ///
    ///        leaf = keccak256(bytes.concat(keccak256(abi.encode(id, wallet, amount))))
    ///
    ///      Hashing twice makes a 64-byte inner node impossible to pass off as a leaf.
    function _leafHash(uint256 id, address wallet, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, wallet, amount))));
    }
}
