// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Reference implementation of the creator payout rule, used by tests to build
///         realistic Merkle trees. Off-chain, MORCast computes payouts with the same rule.
/// @dev For creators with scores s_i > 0 and S = Σ s_i:
///
///        base_i   = (pool × s_i) div S
///        rem_i    = (pool × s_i) mod S
///        leftover = pool − Σ base_i            (always fewer than the number of creators)
///        P_i      = base_i + 1 for the first `leftover` creators ordered by rem_i descending,
///                   then by wallet address ascending; otherwise P_i = base_i
///
///      The result always satisfies Σ P_i == pool.
library PayoutAllocation {
    function allocate(uint256 pool, address[] memory wallets, uint256[] memory scores)
        internal
        pure
        returns (uint256[] memory payouts)
    {
        uint256 n = wallets.length;
        require(scores.length == n, "PayoutAllocation: length mismatch");

        payouts = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; i++) {
            total += scores[i];
        }
        if (total == 0) return payouts;

        // Base share and remainder of every creator.
        uint256[] memory remainders = new uint256[](n);
        uint256 distributed;
        for (uint256 i; i < n; i++) {
            payouts[i] = Math.mulDiv(pool, scores[i], total);
            remainders[i] = mulmod(pool, scores[i], total);
            distributed += payouts[i];
        }

        // Order creators by remainder (descending), then wallet (ascending), with an insertion
        // sort over indices. Test inputs are small, so O(n²) is fine.
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; i++) {
            order[i] = i;
        }
        for (uint256 i = 1; i < n; i++) {
            uint256 current = order[i];
            uint256 j = i;
            while (j > 0 && _before(current, order[j - 1], remainders, wallets)) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = current;
        }

        // Hand out the leftover units, one per creator, in that order.
        uint256 leftover = pool - distributed;
        for (uint256 k; k < leftover; k++) {
            payouts[order[k]] += 1;
        }
    }

    /// @dev True if creator `a` comes before creator `b` in the leftover order.
    function _before(uint256 a, uint256 b, uint256[] memory remainders, address[] memory wallets)
        private
        pure
        returns (bool)
    {
        if (remainders[a] != remainders[b]) return remainders[a] > remainders[b];
        return uint160(wallets[a]) < uint160(wallets[b]);
    }
}
