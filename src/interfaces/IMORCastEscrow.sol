// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMORCastEscrow
/// @notice Public interface of the MORCast campaign escrow.
/// @dev Lifecycle of a campaign (Day N means `endAt + N days`):
///
///        createCampaign ─► Funded ─┬─ cancel (t < startAt) ──────────► Cancelled
///                                  ├─ settle (Day 5 <= t < Day 10) ─► Settled
///                                  └─ withdrawBrand (t >= Day 10) ──► Refunded
///
///      A settled campaign pays out through claim (creators), withdrawFee (treasury) and
///      withdrawBrand (refund of the unspent budget).
///
///      Roles:
///        - Brand:    the address that created the campaign. It can cancel before the start,
///                    withdraw the refund after settlement, and withdraw the whole budget if
///                    the campaign was never settled.
///        - Settler:  one fixed MORCast address. Its only power is to settle each campaign once,
///                    inside the settlement window.
///        - Treasury: the fixed MORCast address that receives protocol fees.
///        - Anyone:   may submit a creator claim (funds always go to the wallet in the Merkle
///                    leaf) or trigger the fee transfer to the treasury.
interface IMORCastEscrow {
    // -------------------------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------------------------

    /// @notice Lifecycle status of a campaign.
    enum Status {
        /// No campaign exists with this ID.
        None,
        /// The budget is escrowed. The campaign waits for settlement, cancellation or refund.
        Funded,
        /// The brand cancelled before `startAt` and received the whole budget back.
        Cancelled,
        /// MORCast settled the campaign. Fee, creator claims and refund are payable.
        Settled,
        /// The campaign was not settled before Day 10 and the brand withdrew the whole budget.
        Refunded
    }

    /// @notice Everything the escrow stores about one campaign.
    /// @dev Fields are ordered so that the small ones share storage slots.
    struct Campaign {
        /// Address that created the campaign and receives refunds.
        address brand;
        /// Campaign start (unix seconds). Creation and cancellation must happen before it.
        uint64 startAt;
        /// Current lifecycle status.
        Status status;
        /// True once the protocol fee has been transferred to the treasury.
        bool feePaid;
        /// True once the post-settlement refund has been transferred to the brand.
        bool refundPaid;
        /// Campaign token: USDC or MOR.
        address token;
        /// Performance cutoff (unix seconds). All settlement deadlines are measured from it.
        uint64 endAt;
        /// B: escrowed budget in token base units.
        uint256 budget;
        /// T: campaign target in the primary metric.
        uint256 target;
        /// Hash of the accepted campaign terms (the manifest).
        bytes32 manifestHash;
        /// S: recognized total reported at settlement.
        uint256 recognized;
        /// G: part of the budget spent on recognized delivery (fee + pool).
        uint256 spent;
        /// Protocol fee: 20% of G.
        uint256 fee;
        /// Creator pool: 80% of G.
        uint256 pool;
        /// Amount returned to the brand after settlement: B − G.
        uint256 refund;
        /// Sum of all creator claims paid so far. Never exceeds `pool`.
        uint256 creatorClaimed;
        /// Root of the Merkle tree of creator payouts.
        bytes32 merkleRoot;
        /// Hash of the published result dataset the settlement is based on.
        bytes32 resultHash;
    }

    // -------------------------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------------------------

    /// @notice A brand escrowed a budget and created a campaign.
    event CampaignCreated(
        uint256 indexed id,
        address indexed brand,
        address indexed token,
        uint256 budget,
        uint256 target,
        uint64 startAt,
        uint64 endAt,
        bytes32 manifestHash
    );

    /// @notice The brand cancelled the campaign before its start and received `amount` back.
    event CampaignCancelled(uint256 indexed id, address indexed brand, uint256 amount);

    /// @notice The settler settled the campaign. The amounts follow the settlement formula.
    event CampaignSettled(
        uint256 indexed id,
        uint256 recognized,
        uint256 spent,
        uint256 fee,
        uint256 pool,
        uint256 refund,
        bytes32 merkleRoot,
        bytes32 resultHash
    );

    /// @notice A creator payout was claimed and `amount` was sent to `wallet`.
    event Claimed(uint256 indexed id, address indexed wallet, uint256 amount);

    /// @notice The protocol fee was sent to the treasury.
    event FeeWithdrawn(uint256 indexed id, address indexed treasury, uint256 amount);

    /// @notice The post-settlement refund was sent to the brand.
    event RefundWithdrawn(uint256 indexed id, address indexed brand, uint256 amount);

    /// @notice The campaign was not settled in time and the whole budget went back to the brand.
    event CampaignRefunded(uint256 indexed id, address indexed brand, uint256 amount);

    // -------------------------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------------------------

    /// @notice A constructor address is the zero address.
    error ZeroAddress();

    /// @notice USDC and MOR were configured with the same address.
    error IdenticalTokens();

    /// @notice The token is neither USDC nor MOR.
    error UnsupportedToken(address token);

    /// @notice The budget is zero or not a multiple of 5.
    error InvalidBudget(uint256 budget);

    /// @notice The target is zero.
    error InvalidTarget();

    /// @notice `startAt` is not before `endAt`, or the campaign lasts longer than
    ///         `MAX_CAMPAIGN_DURATION`.
    error InvalidSchedule(uint64 startAt, uint64 endAt);

    /// @notice The action is only allowed before `startAt`, and `startAt` has been reached.
    error CampaignStarted(uint64 startAt);

    /// @notice The escrow's token balance did not increase by exactly the budget.
    error DepositMismatch(uint256 expected, uint256 received);

    /// @notice No campaign exists with this ID.
    error UnknownCampaign(uint256 id);

    /// @notice Only the campaign's brand may call this function.
    error NotBrand();

    /// @notice Only the settler may call this function.
    error NotSettler();

    /// @notice The campaign's status does not allow this action.
    error InvalidStatus(Status status);

    /// @notice Settlement is only allowed in `[opensAt, closesAt)`.
    error OutsideSettlementWindow(uint256 opensAt, uint256 closesAt);

    /// @notice The creator pool is not empty, but no Merkle root was given to claim it.
    error MissingMerkleRoot();

    /// @notice No result dataset hash was given.
    error MissingResultHash();

    /// @notice The Merkle proof does not prove the leaf against the campaign's root.
    error InvalidProof();

    /// @notice The leaf has already been claimed.
    error AlreadyClaimed();

    /// @notice The claim would pay out more than the remaining creator pool.
    error PoolExceeded(uint256 amount, uint256 remaining);

    /// @notice The fee or the refund has already been withdrawn.
    error AlreadyWithdrawn();

    /// @notice The unsettled campaign cannot be refunded before `availableAt` (Day 10).
    error RefundNotAvailable(uint256 availableAt);

    // -------------------------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------------------------

    /// @notice Escrows `budget` of `token` and creates a campaign. The caller becomes the brand.
    /// @dev Requires a prior ERC-20 approval of at least `budget` for this contract.
    /// @return id The new campaign's ID. IDs start at 1 and increase by 1.
    function createCampaign(
        address token,
        uint256 budget,
        uint256 target,
        uint64 startAt,
        uint64 endAt,
        bytes32 manifestHash
    ) external returns (uint256 id);

    /// @notice Cancels a funded campaign before its start and returns the budget to the brand.
    function cancel(uint256 id) external;

    /// @notice Settles a campaign once, inside `[Day 5, Day 10)`. Only the settler may call it.
    /// @param recognized S, the recognized total from the published result dataset.
    /// @param merkleRoot Root of the creator payout tree (may be zero only if the pool is zero).
    /// @param resultHash Hash of the published result dataset.
    function settle(uint256 id, uint256 recognized, bytes32 merkleRoot, bytes32 resultHash) external;

    /// @notice Pays a creator payout proven by a Merkle proof. Anyone may submit it; the funds
    ///         always go to `wallet`.
    function claim(uint256 id, address wallet, uint256 amount, bytes32[] calldata proof) external;

    /// @notice Sends the protocol fee of a settled campaign to the treasury. Anyone may call it.
    function withdrawFee(uint256 id) external;

    /// @notice Sends the brand its money: the refund of a settled campaign, or the whole budget
    ///         of a campaign that was not settled before Day 10.
    function withdrawBrand(uint256 id) external;

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    /// @notice The only address allowed to settle campaigns.
    function SETTLER() external view returns (address);

    /// @notice The address that receives protocol fees.
    function TREASURY() external view returns (address);

    /// @notice The USDC token accepted as campaign token.
    function USDC() external view returns (address);

    /// @notice The MOR token accepted as campaign token.
    function MOR() external view returns (address);

    /// @notice Delay after `endAt` when settlement opens (Day 5).
    function SETTLEMENT_OPENS_AFTER() external view returns (uint256);

    /// @notice Delay after `endAt` when settlement closes and the full refund opens (Day 10).
    function SETTLEMENT_CLOSES_AFTER() external view returns (uint256);

    /// @notice Longest allowed campaign window, `endAt − startAt` (90 days).
    function MAX_CAMPAIGN_DURATION() external view returns (uint256);

    /// @notice Number of campaigns created so far; also the ID of the latest campaign.
    function campaignCount() external view returns (uint256);

    /// @notice Returns everything stored about a campaign. Unknown IDs return an empty struct
    ///         with status `None`.
    function getCampaign(uint256 id) external view returns (Campaign memory);

    /// @notice Returns true if the leaf with this hash has been claimed.
    function claimed(bytes32 leaf) external view returns (bool);

    /// @notice Returns true if the payout `(id, wallet, amount)` has been claimed.
    function isClaimed(uint256 id, address wallet, uint256 amount) external view returns (bool);

    /// @notice Returns `[opensAt, closesAt)`, the settlement window of a campaign.
    function settlementWindow(uint256 id) external view returns (uint256 opensAt, uint256 closesAt);

    /// @notice Merkle leaf of a creator payout:
    ///         keccak256(bytes.concat(keccak256(abi.encode(id, wallet, amount)))).
    function leafHash(uint256 id, address wallet, uint256 amount) external pure returns (bytes32);

    /// @notice Applies the settlement formula to arbitrary inputs.
    function computeSplit(uint256 budget, uint256 target, uint256 recognized)
        external
        pure
        returns (uint256 spent, uint256 fee, uint256 pool, uint256 refund);
}
