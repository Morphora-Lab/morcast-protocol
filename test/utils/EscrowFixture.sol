// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {MORCastEscrow} from "../../src/MORCastEscrow.sol";
import {MerkleTreeBuilder} from "./MerkleTreeBuilder.sol";
import {MockERC20} from "./Tokens.sol";

/// @notice Shared setup for escrow tests: two mock campaign tokens, a deployed escrow, a funded
///         brand, and helpers to create, settle and claim campaigns.
abstract contract EscrowFixture is Test {
    /// @dev 2026-01-01T00:00:00Z. Tests start from a fixed, realistic timestamp.
    uint256 internal constant START_TIME = 1_767_225_600;

    /// @dev Default campaign from the specification's partial-delivery example.
    uint256 internal constant BUDGET = 100_000e6; // 100,000 USDC
    uint256 internal constant TARGET = 1_000_000;

    bytes32 internal constant MANIFEST_HASH = keccak256("manifest");
    bytes32 internal constant RESULT_HASH = keccak256("result");

    /// @dev A creator payout: one Merkle leaf (campaignId, wallet, amount).
    struct Payout {
        address wallet;
        uint256 amount;
    }

    MockERC20 internal usdc;
    MockERC20 internal mor;
    MORCastEscrow internal escrow;

    address internal owner = makeAddr("owner");
    address internal settler = makeAddr("settler");
    address internal treasury = makeAddr("treasury");
    address internal brand = makeAddr("brand");
    address internal stranger = makeAddr("stranger");

    /// @dev Every campaign created by the helpers runs from Day 1 to Day 15 after START_TIME.
    uint64 internal startAt = uint64(START_TIME + 1 days);
    uint64 internal endAt = uint64(START_TIME + 15 days);

    function setUp() public virtual {
        vm.warp(START_TIME);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        mor = new MockERC20("MorpheusAI", "MOR", 18);
        escrow = new MORCastEscrow(owner, settler, treasury, _tokens(address(usdc), address(mor)));

        _fund(brand, usdc, 10 * BUDGET);
        _fund(brand, mor, 1_000_000e18);
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @dev A token list for the escrow constructor.
    function _tokens(address a) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = a;
    }

    function _tokens(address a, address b) internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = a;
        tokens[1] = b;
    }

    /// @dev Mints `amount` to `account` and approves the escrow to pull it.
    function _fund(address account, MockERC20 token, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(escrow), type(uint256).max);
    }

    /// @dev Creates the default USDC campaign as the brand.
    function _createCampaign() internal returns (uint256) {
        return _createCampaign(address(usdc), BUDGET, TARGET);
    }

    function _createCampaign(address token, uint256 budget, uint256 target)
        internal
        returns (uint256 id)
    {
        vm.prank(brand);
        id = escrow.createCampaign(token, budget, target, startAt, endAt, MANIFEST_HASH);
    }

    /// @dev Timestamp of Day `n`: `endAt + n days`.
    function _day(uint256 n) internal view returns (uint256) {
        return uint256(endAt) + n * 1 days;
    }

    /// @dev Moves to Day 5 and settles as the settler.
    function _settle(uint256 id, uint256 recognized, bytes32 merkleRoot) internal {
        vm.warp(_day(5));
        vm.prank(settler);
        escrow.settle(id, recognized, merkleRoot, RESULT_HASH);
    }

    /// @dev Merkle leaves of `payouts` for campaign `id`, in the escrow's leaf format.
    function _leaves(uint256 id, Payout[] memory payouts)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](payouts.length);
        for (uint256 i; i < payouts.length; i++) {
            leaves[i] = escrow.leafHash(id, payouts[i].wallet, payouts[i].amount);
        }
    }

    /// @dev Merkle root of `payouts` for campaign `id`.
    function _root(uint256 id, Payout[] memory payouts) internal view returns (bytes32) {
        return MerkleTreeBuilder.root(_leaves(id, payouts));
    }

    /// @dev Claims `payouts[index]` with a valid proof, submitted by `caller`.
    function _claim(uint256 id, Payout[] memory payouts, uint256 index, address caller) internal {
        bytes32[] memory proof = MerkleTreeBuilder.proof(_leaves(id, payouts), index);
        vm.prank(caller);
        escrow.claim(id, payouts[index].wallet, payouts[index].amount, proof);
    }
}
