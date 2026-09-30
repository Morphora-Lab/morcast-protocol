/**
 * Settlement arithmetic and creator scoring.
 *
 * `split` mirrors `SettlementMath.split` in the escrow contract exactly. `creatorThreshold`,
 * `creatorScore` and `recognizedTotal` implement the off-chain scoring that produces the
 * recognized total `S` passed to `settle`.
 *
 * Symbols:
 *   B  budget      escrowed amount in token base units (B > 0, B mod 5 == 0)
 *   T  target      campaign goal in the primary metric (T > 0)
 *   M  threshold   minimum total a creator needs to score: ceil(T / 100)
 *   Q  total       sum of a creator's metrics over its passing items
 *   s  score       Q if Q >= M, otherwise 0
 *   S  recognized  sum of all creator scores
 *   G  spent       part of the budget the brand pays: fee + pool
 */

import { assertUint256 } from "./uint.js";

/** The fee is one fifth (20%) of the spent amount. */
export const FEE_DIVISOR = 5n;

/** How a campaign budget is divided at settlement. */
export interface Split {
  /** G: the part of the budget spent on recognized delivery (fee + pool). */
  spent: bigint;
  /** The protocol fee: 20% of G, paid to the MORCast treasury. */
  fee: bigint;
  /** The creator pool: 80% of G, claimed by creators against the Merkle root. */
  pool: bigint;
  /** The amount returned to the brand: B − G. */
  refund: bigint;
}

/**
 * Splits a campaign budget according to the recognized delivery.
 *
 * ```text
 * raw    = floor(B × min(S, T) / T)
 * G      = raw − (raw mod 5)
 * fee    = G / 5
 * pool   = G − fee
 * refund = B − G
 * ```
 *
 * Bigint arithmetic is exact, so this matches the contract (which uses 512-bit `mulDiv`) for
 * every uint256 input.
 *
 * @param budget     B, the escrowed budget in token base units.
 * @param target     T, the campaign target. Must be positive.
 * @param recognized S, the recognized total.
 * @throws RangeError if an input is not a uint256 or the target is zero.
 *
 * @example
 * split(100_000_000_000n, 1_000_000n, 640_000n);
 * // { spent: 64_000_000_000n, fee: 12_800_000_000n, pool: 51_200_000_000n, refund: 36_000_000_000n }
 */
export function split(budget: bigint, target: bigint, recognized: bigint): Split {
  assertUint256(budget, "budget");
  assertUint256(target, "target");
  assertUint256(recognized, "recognized");
  if (target === 0n) throw new RangeError("target must be positive");

  // Delivery above the target is not paid for.
  const capped = recognized < target ? recognized : target;

  // floor(B × min(S, T) / T); never larger than B because min(S, T) <= T.
  const raw = (budget * capped) / target;

  // Round down to a multiple of 5 so that the 20% / 80% split is exact. The dropped remainder
  // (at most 4 base units) stays with the brand.
  const spent = raw - (raw % FEE_DIVISOR);
  const fee = spent / FEE_DIVISOR;

  return { spent, fee, pool: spent - fee, refund: budget - spent };
}

/**
 * The creator threshold `M = ceil(T / 100)`: a creator whose total is below `M` scores zero.
 *
 * @example
 * creatorThreshold(1_000_000n); // 10_000n
 * creatorThreshold(3_000n);     // 30n
 */
export function creatorThreshold(target: bigint): bigint {
  assertUint256(target, "target");
  if (target === 0n) throw new RangeError("target must be positive");
  return (target + 99n) / 100n;
}

/**
 * A creator's score: its total `Q` if `Q >= M`, otherwise zero.
 *
 * @param total     Q, the sum of the creator's metrics over its passing items.
 * @param threshold M, from {@link creatorThreshold}.
 */
export function creatorScore(total: bigint, threshold: bigint): bigint {
  assertUint256(total, "total");
  assertUint256(threshold, "threshold");
  return total >= threshold ? total : 0n;
}

/**
 * The recognized total `S`: the sum of all creator scores.
 *
 * @throws RangeError if a score is negative or the sum does not fit in a uint256.
 */
export function recognizedTotal(scores: readonly bigint[]): bigint {
  let total = 0n;
  for (const score of scores) {
    assertUint256(score, "score");
    total += score;
  }
  assertUint256(total, "recognized total");
  return total;
}
