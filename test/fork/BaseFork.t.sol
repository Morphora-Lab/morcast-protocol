// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {MORCastEscrow} from "../../src/MORCastEscrow.sol";
import {IMORCastEscrow} from "../../src/interfaces/IMORCastEscrow.sol";
import {MerkleTreeBuilder} from "../utils/MerkleTreeBuilder.sol";

/// @notice Runs the escrow against the real USDC and MOR contracts on a fork of Base mainnet.
/// @dev Requires the BASE_RPC_URL environment variable; the suite is skipped without it.
///      Balances are set with `deal`, so no real funds are involved.
contract BaseForkTest is Test {
    /// @dev Circle-issued USDC on Base (6 decimals).
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Morpheus MOR on Base (18 decimals).
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    MORCastEscrow internal escrow;
    address internal settler = makeAddr("settler");
    address internal treasury = makeAddr("treasury");
    address internal brand = makeAddr("brand");
    address internal creatorA = makeAddr("creator A");
    address internal creatorB = makeAddr("creator B");

    uint64 internal startAt;
    uint64 internal endAt;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        escrow = new MORCastEscrow(settler, treasury, USDC, MOR);
        startAt = uint64(block.timestamp + 1 days);
        endAt = uint64(block.timestamp + 15 days);
    }

    function test_tokens_matchExpectedContracts() public view {
        assertEq(IERC20Metadata(USDC).symbol(), "USDC");
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertEq(IERC20Metadata(MOR).symbol(), "MOR");
        assertEq(IERC20Metadata(MOR).decimals(), 18);
    }

    /// @notice Full USDC lifecycle: deposit, settlement, two claims, fee and refund.
    function test_lifecycle_withUsdc() public {
        _lifecycle(USDC, 100_000e6);
    }

    /// @notice Full MOR lifecycle: deposit, settlement, two claims, fee and refund.
    function test_lifecycle_withMor() public {
        _lifecycle(MOR, 25_000e18);
    }

    /// @notice An unsettled MOR campaign is fully refunded from Day 10.
    function test_refundFromDay10_withMor() public {
        uint256 budget = 10_000e18;
        uint256 id = _create(MOR, budget);

        vm.warp(uint256(endAt) + 10 days);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(IERC20Metadata(MOR).balanceOf(brand), budget);
        assertEq(IERC20Metadata(MOR).balanceOf(address(escrow)), 0);
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @dev Target 1,000,000 and recognized 640,000: 64% of the budget is spent, split into a
    ///      fee (20%) and a pool (80%) paid to two creators in a 3:1 ratio.
    function _lifecycle(address token, uint256 budget) private {
        IERC20Metadata erc20 = IERC20Metadata(token);
        uint256 id = _create(token, budget);

        uint256 spent = budget * 64 / 100;
        uint256 fee = spent / 5;
        uint256 pool = spent - fee;
        uint256 payoutA = pool * 3 / 4;
        uint256 payoutB = pool - payoutA;

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = escrow.leafHash(id, creatorA, payoutA);
        leaves[1] = escrow.leafHash(id, creatorB, payoutB);

        vm.warp(uint256(endAt) + 5 days);
        vm.prank(settler);
        escrow.settle(id, 640_000, MerkleTreeBuilder.root(leaves), keccak256("result"));
        assertEq(escrow.getCampaign(id).pool, pool);

        escrow.claim(id, creatorA, payoutA, MerkleTreeBuilder.proof(leaves, 0));
        escrow.claim(id, creatorB, payoutB, MerkleTreeBuilder.proof(leaves, 1));
        escrow.withdrawFee(id);
        vm.prank(brand);
        escrow.withdrawBrand(id);

        assertEq(erc20.balanceOf(creatorA), payoutA);
        assertEq(erc20.balanceOf(creatorB), payoutB);
        assertEq(erc20.balanceOf(treasury), fee);
        assertEq(erc20.balanceOf(brand), budget - spent);
        assertEq(erc20.balanceOf(address(escrow)), 0);
    }

    function _create(address token, uint256 budget) private returns (uint256 id) {
        deal(token, brand, budget);
        vm.startPrank(brand);
        IERC20Metadata(token).approve(address(escrow), budget);
        id = escrow.createCampaign(token, budget, 1_000_000, startAt, endAt, keccak256("manifest"));
        vm.stopPrank();
        assertEq(uint8(escrow.getCampaign(id).status), uint8(IMORCastEscrow.Status.Funded));
    }
}
