// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SettlementMath
/// @notice Settlement arithmetic of a Morcast campaign. It defines how the escrowed budget is
///         divided between the protocol fee, the creator pool and the brand refund.
/// @dev Symbols used throughout the protocol:
///
///        B  budget      amount the brand escrowed, in token base units (B > 0, B mod 5 == 0)
///        T  target      campaign goal in the campaign's primary metric (T > 0)
///        S  recognized  total recognized delivery reported by Morcast at settlement
///        G  spent       part of the budget the brand pays for recognized delivery
///
///      Formula:
///
///        G      = floor(B × min(S, T) / T), rounded down to a multiple of 5
///        fee    = G / 5          (20% of G, paid to the Morcast treasury)
///        pool   = 4 × G / 5      (80% of G, claimed by creators)
///        refund = B − G          (returned to the brand)
///
///      Consequences:
///        - One recognized unit is worth B / T, so the brand never pays more than B.
///        - S >= T  =>  G == B. The target is reached and the whole budget is spent.
///        - S == 0  =>  G == 0. Nothing was recognized and the brand gets everything back.
///        - fee + pool + refund == B for every input, so no base unit is created or lost.
///
///      All arithmetic is exact integer arithmetic, and every division rounds down.
library SettlementMath {
    /// @notice The fee is one fifth (20%) of the spent amount.
    /// @dev G is rounded down to a multiple of this value so that G / 5 and 4 × G / 5 are exact.
    uint256 internal constant FEE_DIVISOR = 5;

    /// @notice Splits a campaign budget according to the recognized delivery.
    /// @dev Reverts with a division-by-zero panic when `target` is zero. A campaign can never
    ///      have a zero target, because the escrow rejects it at creation.
    /// @param budget     B, the escrowed budget in token base units.
    /// @param target     T, the campaign target in the primary metric.
    /// @param recognized S, the recognized total in the primary metric.
    /// @return spent  G, the amount the brand pays: fee + pool.
    /// @return fee    The protocol fee, 20% of G.
    /// @return pool   The creator pool, 80% of G.
    /// @return refund The amount returned to the brand: B − G.
    function split(uint256 budget, uint256 target, uint256 recognized)
        internal
        pure
        returns (uint256 spent, uint256 fee, uint256 pool, uint256 refund)
    {
        // Delivery above the target is not paid for, so S is capped at T.
        uint256 capped = recognized < target ? recognized : target;

        // floor(B × min(S, T) / T).
        // Math.mulDiv computes the product with 512-bit precision before dividing, so the
        // result is exact even when B × min(S, T) does not fit in 256 bits.
        // Because min(S, T) <= T, the result is never larger than B.
        uint256 raw = Math.mulDiv(budget, capped, target);

        // Round down to a multiple of 5. The dropped remainder (at most 4 base units) is part
        // of the refund, so rounding always favours the brand.
        spent = raw - (raw % FEE_DIVISOR);

        // spent is a multiple of 5, so both parts are exact:
        //   fee  = spent / 5
        //   pool = spent − spent / 5 = 4 × spent / 5
        fee = spent / FEE_DIVISOR;
        pool = spent - fee;

        // spent <= raw <= budget, so this subtraction cannot underflow.
        refund = budget - spent;
    }
}
