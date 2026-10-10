// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMorcastEscrow} from "./interfaces/IMorcastEscrow.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";

/// @title MorcastEscrow
/// @notice Escrow for Morcast creator campaigns.
///
///         A brand escrows a budget in an allowed token (USDC or MOR). After the campaign,
///         Morcast measures and verifies performance off-chain, publishes the result dataset and
///         settles the campaign once with the recognized total S. The contract derives the fee,
///         the creator pool and the brand refund from S with a fixed formula, pays creators
///         against a Merkle root, and returns the whole budget to the brand if Morcast does not
///         settle in time.
///
/// @dev Design rules:
///        - The contract holds money, pays it out once according to the fixed formula, and
///          refunds the brand if the campaign is not settled. Everything else happens off-chain.
///        - The code cannot be upgraded. The economic rules (the formula, the fee, Day 5, Day 10
///          and the 90-day maximum) are constants. A new version is a new deployment.
///        - The settler's only power is `settle`, once per campaign, inside the settlement window.
///        - The owner operates the escrow. It can replace the settler and the treasury, allow
///          tokens and pause creation for new campaigns, void a funded campaign (the budget goes
///          back to its brand) and recover tokens that no campaign is owed. It can never move a
///          campaign's money anywhere else.
///        - Every campaign has its own accounting. A campaign never pays out more than its own
///          budget, whatever happens to other campaigns. `totalOwed` tracks, per token, exactly
///          what all campaigns are still owed.
///        - State is updated and events are emitted before every token transfer, transfers use
///          SafeERC20, and every function that moves tokens is also protected by a reentrancy
///          guard.
///        - Settlement is final and entitlements never expire.
contract MorcastEscrow is IMorcastEscrow, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    /// @dev The code cannot be upgraded, so every new version is a new deployment with its own
    ///      address. Off-chain systems use this value to tell deployments apart.
    string public constant VERSION = "1.0.0";

    /// @inheritdoc IMorcastEscrow
    /// @dev Day 5. Results are published by Day 4 and reviewed until at least Day 5.
    uint256 public constant SETTLEMENT_OPENS_AFTER = 5 days;

    /// @inheritdoc IMorcastEscrow
    /// @dev Day 10. Settlement is no longer possible and the brand may take the budget back.
    uint256 public constant SETTLEMENT_CLOSES_AFTER = 10 days;

    /// @inheritdoc IMorcastEscrow
    /// @dev Once a campaign has started, its budget stays escrowed until settlement or the Day-10
    ///      refund, so a wrong `endAt` (for example milliseconds instead of seconds) would lock
    ///      the budget for a very long time. Capping the length rules that out.
    uint256 public constant MAX_CAMPAIGN_DURATION = 90 days;

    // -------------------------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    address public settler;

    /// @inheritdoc IMorcastEscrow
    address public treasury;

    /// @inheritdoc IMorcastEscrow
    bool public creationPaused;

    /// @inheritdoc IMorcastEscrow
    mapping(address token => bool) public isCampaignToken;

    /// @inheritdoc IMorcastEscrow
    /// @dev Increased by every deposit and decreased by every payout, so for each token it always
    ///      equals the sum of what the campaigns in that token are still owed. The escrow's
    ///      balance above this amount belongs to no campaign and is what `recoverTokens` returns.
    mapping(address token => uint256) public totalOwed;

    /// @inheritdoc IMorcastEscrow
    uint256 public campaignCount;

    /// @dev Campaign ID => campaign. IDs start at 1, so ID 0 never exists.
    mapping(uint256 id => Campaign) private _campaigns;

    /// @inheritdoc IMorcastEscrow
    /// @dev Keyed by leaf hash. The leaf includes the campaign ID, so one global mapping is
    ///      enough to track claims of all campaigns.
    mapping(bytes32 leaf => bool) public claimed;

    // -------------------------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------------------------

    /// @param initialOwner    Owner of the escrow, a wallet Morcast holds.
    /// @param initialSettler  The only address allowed to settle campaigns.
    /// @param initialTreasury The address that receives protocol fees.
    /// @param initialTokens   Tokens allowed for campaigns (on Base: USDC and MOR).
    constructor(
        address initialOwner,
        address initialSettler,
        address initialTreasury,
        address[] memory initialTokens
    ) Ownable(initialOwner) {
        // A settler is required at deployment. The owner can disable it later if needed.
        if (initialSettler == address(0)) revert ZeroAddress();
        _setSettler(initialSettler);
        _setTreasury(initialTreasury);
        for (uint256 i; i < initialTokens.length; i++) {
            _setCampaignToken(initialTokens[i], true);
        }
    }

    // -------------------------------------------------------------------------------------------
    // Brand: create and cancel
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    function createCampaign(
        address token,
        uint256 budget,
        uint256 target,
        uint64 startAt,
        uint64 endAt,
        bytes32 manifestHash
    ) external nonReentrant returns (uint256 id) {
        // The owner can pause campaign creation, for example while a problem is investigated.
        if (creationPaused) revert CreationPaused();

        // Only tokens allowed by the owner can be used for new campaigns.
        if (!isCampaignToken[token]) revert UnsupportedToken(token);

        // A multiple of 5 guarantees that a fully spent budget splits exactly into 20% / 80%.
        if (budget == 0 || budget % SettlementMath.FEE_DIVISOR != 0) revert InvalidBudget(budget);

        // The target is the divisor of the settlement formula, so it must be positive.
        if (target == 0) revert InvalidTarget();

        // The campaign window [startAt, endAt) must not be empty and must last at most 90 days.
        // `endAt - startAt` cannot underflow, because the first condition is checked first.
        if (startAt >= endAt || endAt - startAt > MAX_CAMPAIGN_DURATION) {
            revert InvalidSchedule(startAt, endAt);
        }

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
        totalOwed[token] += budget;

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

    /// @inheritdoc IMorcastEscrow
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
        totalOwed[campaign.token] -= amount;
        emit CampaignCancelled(id, msg.sender, amount);

        IERC20(campaign.token).safeTransfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Settler: settle
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    function settle(uint256 id, uint256 recognized, bytes32 merkleRoot, bytes32 resultHash)
        external
    {
        // When the owner has disabled settlement, `settler` is zero and nobody passes this check.
        if (msg.sender != settler) revert NotSettler();

        Campaign storage campaign = _load(id);

        // Only a funded campaign can be settled, which also makes settlement happen at most once.
        if (campaign.status != Status.Funded) revert InvalidStatus(campaign.status);

        // Settlement is allowed only in [Day 5, Day 10).
        (uint256 opensAt, uint256 closesAt) = _settlementWindow(campaign.endAt);
        if (block.timestamp < opensAt || block.timestamp >= closesAt) {
            revert OutsideSettlementWindow(opensAt, closesAt);
        }

        // The split is computed here from S. The settler cannot choose the amounts directly.
        (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
            SettlementMath.split(campaign.budget, campaign.target, recognized);

        // A non-empty pool with a zero root could never be claimed and would be locked forever.
        if (pool != 0 && merkleRoot == bytes32(0)) revert MissingMerkleRoot();

        // Every settlement refers to a published result dataset, even when nothing is paid.
        if (resultHash == bytes32(0)) revert MissingResultHash();

        // The campaign is still owed its whole budget, because fee + pool + refund == budget.
        // So `totalOwed` does not change here.
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

    /// @inheritdoc IMorcastEscrow
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

        // Defence in depth. Even a wrong tree can never pay out more than the creator pool.
        uint256 remaining = campaign.pool - campaign.creatorClaimed;
        if (amount > remaining) revert PoolExceeded(amount, remaining);

        // Update state and emit the event first, then transfer. The funds go to the leaf's
        // wallet, never to the caller, so anyone (for example a gas-sponsoring relayer) can
        // submit the claim.
        claimed[leaf] = true;
        campaign.creatorClaimed += amount;
        totalOwed[campaign.token] -= amount;
        // MerkleProof is an internal library call (a jump, not an external call), so no external
        // code runs before this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(id, wallet, amount);

        IERC20(campaign.token).safeTransfer(wallet, amount);
    }

    /// @inheritdoc IMorcastEscrow
    function withdrawFee(uint256 id) external nonReentrant {
        Campaign storage campaign = _load(id);
        if (campaign.status != Status.Settled) revert InvalidStatus(campaign.status);
        if (campaign.feePaid) revert AlreadyWithdrawn();

        campaign.feePaid = true;
        uint256 fee = campaign.fee;
        totalOwed[campaign.token] -= fee;
        // The fee goes to the treasury in place now, which the owner may have replaced.
        address recipient = treasury;
        emit FeeWithdrawn(id, recipient, fee);

        // A zero fee (nothing recognized) is marked as paid without a transfer.
        if (fee != 0) IERC20(campaign.token).safeTransfer(recipient, fee);
    }

    /// @inheritdoc IMorcastEscrow
    function withdrawBrand(uint256 id) external nonReentrant {
        Campaign storage campaign = _load(id);
        if (msg.sender != campaign.brand) revert NotBrand();

        Status status = campaign.status;

        if (status == Status.Settled) {
            // Case 1. The campaign was settled. The brand receives B − G, once.
            if (campaign.refundPaid) revert AlreadyWithdrawn();

            campaign.refundPaid = true;
            uint256 refund = campaign.refund;
            totalOwed[campaign.token] -= refund;
            emit RefundWithdrawn(id, msg.sender, refund);

            // A zero refund (target reached) is marked as paid without a transfer.
            if (refund != 0) IERC20(campaign.token).safeTransfer(msg.sender, refund);
        } else if (status == Status.Funded) {
            // Case 2. The campaign was never settled. From Day 10 the brand receives the whole
            // budget, and the campaign can no longer be settled.
            (, uint256 closesAt) = _settlementWindow(campaign.endAt);
            if (block.timestamp < closesAt) revert RefundNotAvailable(closesAt);

            campaign.status = Status.Refunded;
            uint256 budget = campaign.budget;
            totalOwed[campaign.token] -= budget;
            emit CampaignRefunded(id, msg.sender, budget);

            IERC20(campaign.token).safeTransfer(msg.sender, budget);
        } else {
            // Cancelled and Refunded campaigns have nothing left to withdraw.
            revert InvalidStatus(status);
        }
    }

    // -------------------------------------------------------------------------------------------
    // Owner actions
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    /// @dev The zero address is allowed. It disables settlement, which only ever leads to the
    ///      brands' full refunds from Day 10.
    function setSettler(address newSettler) external onlyOwner {
        _setSettler(newSettler);
    }

    /// @inheritdoc IMorcastEscrow
    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
    }

    /// @inheritdoc IMorcastEscrow
    function setCampaignToken(address token, bool allowed) external onlyOwner {
        _setCampaignToken(token, allowed);
    }

    /// @inheritdoc IMorcastEscrow
    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedUpdated(paused);
    }

    /// @inheritdoc IMorcastEscrow
    /// @dev Only a funded campaign can be voided, and its budget can only go to its brand. Used
    ///      to release a budget deposited by mistake without waiting for the settlement window,
    ///      or to return every budget to its brand in an emergency.
    function voidCampaign(uint256 id) external nonReentrant onlyOwner {
        Campaign storage campaign = _load(id);
        if (campaign.status != Status.Funded) revert InvalidStatus(campaign.status);

        campaign.status = Status.Refunded;
        address brand = campaign.brand;
        uint256 budget = campaign.budget;
        totalOwed[campaign.token] -= budget;
        emit CampaignVoided(id, brand, budget);

        IERC20(campaign.token).safeTransfer(brand, budget);
    }

    /// @inheritdoc IMorcastEscrow
    /// @dev The amount is the balance above `totalOwed[token]`, so campaign funds are never
    ///      touched. For a token no campaign uses, that is the whole balance.
    function recoverTokens(address token, address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 excess = IERC20(token).balanceOf(address(this)) - totalOwed[token];
        if (excess == 0) revert NothingToRecover();
        emit TokensRecovered(token, to, excess);

        IERC20(token).safeTransfer(to, excess);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMorcastEscrow
    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return _campaigns[id];
    }

    /// @inheritdoc IMorcastEscrow
    function isClaimed(uint256 id, address wallet, uint256 amount) external view returns (bool) {
        return claimed[_leafHash(id, wallet, amount)];
    }

    /// @inheritdoc IMorcastEscrow
    function settlementWindow(uint256 id)
        external
        view
        returns (uint256 opensAt, uint256 closesAt)
    {
        return _settlementWindow(_load(id).endAt);
    }

    /// @inheritdoc IMorcastEscrow
    function leafHash(uint256 id, address wallet, uint256 amount) external pure returns (bytes32) {
        return _leafHash(id, wallet, amount);
    }

    /// @inheritdoc IMorcastEscrow
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

    function _setSettler(address newSettler) private {
        address previous = settler;
        settler = newSettler;
        emit SettlerUpdated(previous, newSettler);
    }

    function _setTreasury(address newTreasury) private {
        // Fees sent to the zero address would fail, so a treasury is always required.
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function _setCampaignToken(address token, bool allowed) private {
        // Also called in the constructor's loop, where a zero token must abort the deployment.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (token == address(0)) revert ZeroAddress();
        isCampaignToken[token] = allowed;
        emit CampaignTokenUpdated(token, allowed);
    }

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
