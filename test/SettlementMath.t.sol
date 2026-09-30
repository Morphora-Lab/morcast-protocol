// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {SettlementMath} from "../src/libraries/SettlementMath.sol";

/// @dev Exposes the internal library function through an external call, so that a test can
///      expect a revert from it.
contract SettlementMathHarness {
    function split(uint256 budget, uint256 target, uint256 recognized)
        external
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        return SettlementMath.split(budget, target, recognized);
    }
}

contract SettlementMathTest is Test {
    /// @dev Shared test vectors. Off-chain implementations test against the same file.
    string internal constant VECTORS = "/vectors/settlement.json";

    SettlementMathHarness internal harness;

    function setUp() public {
        harness = new SettlementMathHarness();
    }

    // ---------------------------------------------------------------------------------------
    // Fixed vectors
    // ---------------------------------------------------------------------------------------

    /// @notice Every case in vectors/settlement.json must match exactly, field by field.
    function test_split_matchesSharedVectors() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), VECTORS));

        uint256 count;
        // Walk the "cases" array until the next index no longer exists.
        while (vm.keyExistsJson(json, _case(count, ""))) {
            string memory name = vm.parseJsonString(json, _case(count, ".name"));

            (uint256 spent, uint256 fee, uint256 pool, uint256 refund) = SettlementMath.split(
                vm.parseJsonUint(json, _case(count, ".budget")),
                vm.parseJsonUint(json, _case(count, ".target")),
                vm.parseJsonUint(json, _case(count, ".recognized"))
            );

            assertEq(spent, vm.parseJsonUint(json, _case(count, ".spent")), name);
            assertEq(fee, vm.parseJsonUint(json, _case(count, ".fee")), name);
            assertEq(pool, vm.parseJsonUint(json, _case(count, ".pool")), name);
            assertEq(refund, vm.parseJsonUint(json, _case(count, ".refund")), name);
            count++;
        }

        // Guards against a silently empty or unreadable vector file.
        assertGt(count, 0, "no vectors loaded");
    }

    /// @notice A zero target has no meaning and reverts with a division-by-zero panic.
    function test_split_revertsOnZeroTarget() public {
        vm.expectRevert(stdError.divisionError);
        harness.split(100, 0, 1);
    }

    // ---------------------------------------------------------------------------------------
    // Properties (fuzzed)
    // ---------------------------------------------------------------------------------------

    /// @notice No base unit is created or lost: fee + pool + refund == budget, spent is a
    ///         multiple of 5, never exceeds the budget, and the pool is exactly 4 × fee.
    function testFuzz_split_conservesBudget(uint256 budget, uint256 target, uint256 recognized)
        public
        pure
    {
        target = bound(target, 1, type(uint256).max);

        (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
            SettlementMath.split(budget, target, recognized);

        assertEq(fee + pool + refund, budget, "fee + pool + refund != budget");
        assertEq(fee + pool, spent, "fee + pool != spent");
        assertEq(spent % 5, 0, "spent is not a multiple of 5");
        assertLe(spent, budget, "spent > budget");
        assertEq(pool, 4 * fee, "pool != 4 x fee");
    }

    /// @notice Reaching or exceeding the target spends exactly the whole budget.
    function testFuzz_split_targetReachedSpendsWholeBudget(
        uint256 budget,
        uint256 target,
        uint256 recognized
    ) public pure {
        // Campaign budgets are always multiples of 5.
        budget = bound(budget, 1, type(uint256).max / 5) * 5;
        target = bound(target, 1, type(uint256).max);
        recognized = bound(recognized, target, type(uint256).max);

        (uint256 spent,,, uint256 refund) = SettlementMath.split(budget, target, recognized);

        assertEq(spent, budget);
        assertEq(refund, 0);
    }

    /// @notice Nothing recognized means nothing is spent and the brand gets everything back.
    function testFuzz_split_nothingRecognizedSpendsNothing(uint256 budget, uint256 target)
        public
        pure
    {
        target = bound(target, 1, type(uint256).max);

        (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
            SettlementMath.split(budget, target, 0);

        assertEq(spent, 0);
        assertEq(fee, 0);
        assertEq(pool, 0);
        assertEq(refund, budget);
    }

    /// @notice Matches a direct evaluation of the formula whenever B × min(S, T) fits in 256
    ///         bits. Inputs are limited to 128 bits so that the product cannot overflow.
    function testFuzz_split_matchesDirectFormula(uint128 budget, uint128 target, uint256 recognized)
        public
        pure
    {
        vm.assume(target > 0);

        uint256 capped = recognized < target ? recognized : uint256(target);
        uint256 raw = uint256(budget) * capped / target;
        uint256 expectedSpent = raw - raw % 5;

        (uint256 spent, uint256 fee, uint256 pool, uint256 refund) =
            SettlementMath.split(budget, target, recognized);

        assertEq(spent, expectedSpent);
        assertEq(fee, expectedSpent / 5);
        assertEq(pool, 4 * expectedSpent / 5);
        assertEq(refund, budget - expectedSpent);
    }

    /// @notice More recognized delivery never lowers the amount spent.
    function testFuzz_split_monotonicInRecognized(
        uint256 budget,
        uint256 target,
        uint256 lower,
        uint256 higher
    ) public pure {
        target = bound(target, 1, type(uint256).max);
        if (lower > higher) (lower, higher) = (higher, lower);

        (uint256 spentLower,,,) = SettlementMath.split(budget, target, lower);
        (uint256 spentHigher,,,) = SettlementMath.split(budget, target, higher);

        assertLe(spentLower, spentHigher);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev JSON path of a field of case `index`, for example `.cases[3].budget`.
    function _case(uint256 index, string memory field) private pure returns (string memory) {
        return string.concat(".cases[", vm.toString(index), "]", field);
    }
}
