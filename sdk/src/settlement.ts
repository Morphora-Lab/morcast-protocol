/**
 * Settlement arithmetic and creator scoring.
 *
 * `split` mirrors `SettlementMath.split` in the escrow contract exactly. `creatorThreshold`,
 * `creatorScore` and `recognizedTotal` implement the off-chain scoring that produces the
 * recognized total `S` passed to `settle`.
 *
 * Symbols:
 *   B  budget      escrowed amount in token base units (B > 0, B mod 25 == 0)
 *   T  target      campaign goal in the primary metric (T > 0)
 *   M  threshold   minimum total a creator needs to score: ceil(T / 100)
 *   Q  total       sum of a creator's metrics over its passing items
 *   s  score       Q if Q >= M, otherwise 0
 *   S  recognized  sum of all creator scores
 *   G  spent       part of the budget the brand pays: fee + pool
 */

import { assertUint256 } from "./uint.js";

/** The fee is 2 parts in 25 (8%) of the spent amount: `FEE_NUMERATOR / FEE_DENOMINATOR`. */
export const FEE_NUMERATOR = 2n;

/**
 * The fee's denominator. The spent amount is rounded down to a multiple of it, so the fee and the
 * pool are exact, and a campaign budget must be a multiple of it too.
 */
export const FEE_DENOMINATOR = 25n;

/** How a campaign budget is divided at settlement. */
export interface Split {
  /** G: the part of the budget spent on recognized delivery (fee + pool). */
  spent: bigint;
  /** The protocol fee: 8% of G, paid to the Morcast treasury. */
  fee: bigint;
  /** The creator pool: 92% of G, claimed by creators against the Merkle root. */
  pool: bigint;
  /** The amount returned to the brand: B − G. */
  refund: bigint;
}

/**
 * Splits a campaign budget according to the recognized delivery.
 *
 * ```text
 * raw    = floor(B × min(S, T) / T)
 * G      = raw − (raw mod 25)
 * fee    = G / 25 × 2
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
 * // { spent: 64_000_000_000n, fee: 5_120_000_000n, pool: 58_880_000_000n, refund: 36_000_000_000n }
 */
export function split(budget: bigint, target: bigint, recognized: bigint): Split {
  assertUint256(budget, "budget");
  assertUint256(target, "target");
  assertUint256(recognized, "recognized");
  if (target === 0n) throw new RangeError("target must be positive");

  // Delivery above the target is not paid for.
  const capped = recognized < target ? recognized : target;

  // floor(B × min(S, T) / T). Never larger than B because min(S, T) <= T.
  const raw = (budget * capped) / target;

  // Round down to a multiple of 25 so that the 8% / 92% split is exact. The dropped remainder
  // (at most 24 base units) stays with the brand.
  const spent = raw - (raw % FEE_DENOMINATOR);
  // spent is a multiple of 25, so dividing first is exact, as in the contract.
  const fee = (spent / FEE_DENOMINATOR) * FEE_NUMERATOR;

  return { spent, fee, pool: spent - fee, refund: budget - spent };
}

/**
 * The creator threshold `M = ceil(T / 100)`: a creator whose total is below `M` scores zero.
 *
 * @example
 * creatorThreshold(1_000_000n). // 10_000n
 * creatorThreshold(3_000n).     // 30n
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
