// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {PayoutAllocation} from "./utils/PayoutAllocation.sol";

/// @notice Checks the reference payout rule (used by the invariant tests to build Merkle trees)
///         against the shared payout vectors, and fuzzes its basic properties.
contract PayoutAllocationTest is Test {
    string internal constant VECTORS = "/vectors/payouts.json";

    /// @notice Every case in vectors/payouts.json must match exactly.
    function test_allocate_matchesSharedVectors() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), VECTORS));

        uint256 cases;
        while (vm.keyExistsJson(json, _case(cases, ""))) {
            string memory name = vm.parseJsonString(json, _case(cases, ".name"));
            uint256 pool = vm.parseJsonUint(json, _case(cases, ".pool"));

            // Count the creators of this case, then read them.
            uint256 n;
            while (vm.keyExistsJson(json, _creator(cases, n, ""))) {
                n++;
            }
            address[] memory wallets = new address[](n);
            uint256[] memory scores = new uint256[](n);
            uint256[] memory expected = new uint256[](n);
            for (uint256 i; i < n; i++) {
                wallets[i] = vm.parseJsonAddress(json, _creator(cases, i, ".wallet"));
                scores[i] = vm.parseJsonUint(json, _creator(cases, i, ".score"));
                expected[i] = vm.parseJsonUint(json, _creator(cases, i, ".payout"));
            }

            uint256[] memory payouts = PayoutAllocation.allocate(pool, wallets, scores);
            for (uint256 i; i < n; i++) {
                assertEq(payouts[i], expected[i], name);
            }
            cases++;
        }

        assertGt(cases, 0, "no vectors loaded");
    }

    /// @notice Payouts always add up to the pool, and no creator receives more than one unit
    ///         above its exact proportional share.
    function testFuzz_allocate_distributesWholePool(uint256 pool, uint256[5] memory rawScores)
        public
        pure
    {
        pool = bound(pool, 0, 1e30);
        address[] memory wallets = new address[](5);
        uint256[] memory scores = new uint256[](5);
        uint256 total;
        for (uint256 i; i < 5; i++) {
            wallets[i] = address(uint160(i + 1));
            scores[i] = bound(rawScores[i], 1, 1e18);
            total += scores[i];
        }

        uint256[] memory payouts = PayoutAllocation.allocate(pool, wallets, scores);

        uint256 sum;
        for (uint256 i; i < 5; i++) {
            uint256 exactFloor = pool * scores[i] / total;
            assertGe(payouts[i], exactFloor);
            assertLe(payouts[i], exactFloor + 1);
            sum += payouts[i];
        }
        assertEq(sum, pool);
    }

    function _case(uint256 index, string memory field) private pure returns (string memory) {
        return string.concat(".cases[", vm.toString(index), "]", field);
    }

    function _creator(uint256 caseIndex, uint256 creatorIndex, string memory field)
        private
        pure
        returns (string memory)
    {
        return string.concat(_case(caseIndex, ".creators["), vm.toString(creatorIndex), "]", field);
    }
}
