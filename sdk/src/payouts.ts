/**
 * Creator payouts: how the creator pool is divided among creators in proportion to their scores.
 */

import { type Address, isAddress } from "viem";

import { assertUint256 } from "./uint.js";

/** A creator's score in a campaign. */
export interface CreatorScore {
  /** The creator's payout wallet. */
  wallet: Address;
  /** s: the creator's score (zero if its total is below the threshold). */
  score: bigint;
}

/** A creator's score together with its payout. */
export interface CreatorPayout extends CreatorScore {
  /** P: the creator's share of the pool, in token base units. */
  payout: bigint;
}

/**
 * Divides `pool` among creators in proportion to their scores.
 *
 * Over the creators with a positive score, where `S` is the sum of those scores:
 *
 * ```text
 * base_i   = (pool × s_i) div S
 * rem_i    = (pool × s_i) mod S
 * leftover = pool − Σ base_i            (always fewer than the number of scoring creators)
 * P_i      = base_i + 1 for the first `leftover` creators ordered by rem_i descending, then by
 *            wallet address ascending (compared as 160-bit integers); otherwise P_i = base_i
 * ```
 *
 * Creators with a zero score receive zero. The payouts always add up to exactly `pool`. The
 * result keeps the input order.
 *
 * @throws RangeError if a wallet is invalid or repeated, or a value is not a uint256.
 *
 * @example
 * allocatePayouts(800_000_000n, [
 *   { wallet: "0x0000000000000000000000000000000000000001", score: 1_000n },
 *   { wallet: "0x0000000000000000000000000000000000000002", score: 1_000n },
 *   { wallet: "0x0000000000000000000000000000000000000003", score: 1_000n },
 * ]);
 * // payouts 266_666_667n, 266_666_667n, 266_666_666n: the two leftover units go to the
 * // lowest addresses because all remainders are equal.
 */
export function allocatePayouts(pool: bigint, creators: readonly CreatorScore[]): CreatorPayout[] {
  assertUint256(pool, "pool");
  validateCreators(creators);

  const payouts = creators.map((creator) => ({ ...creator, payout: 0n }));
  const scoring = payouts.filter((creator) => creator.score > 0n);
  const total = scoring.reduce((sum, creator) => sum + creator.score, 0n);
  if (total === 0n) return payouts;

  // Base share and remainder of every scoring creator.
  const remainders = new Map<CreatorPayout, bigint>();
  let distributed = 0n;
  for (const creator of scoring) {
    creator.payout = (pool * creator.score) / total;
    remainders.set(creator, (pool * creator.score) % total);
    distributed += creator.payout;
  }

  // Hand out the leftover units, one per creator: largest remainder first, then lowest wallet.
  const order = [...scoring].sort((a, b) => {
    const byRemainder = compare(remainders.get(b) ?? 0n, remainders.get(a) ?? 0n);
    return byRemainder !== 0 ? byRemainder : compare(BigInt(a.wallet), BigInt(b.wallet));
  });
  const leftover = pool - distributed;
  for (let k = 0; BigInt(k) < leftover; k++) {
    const creator = order[k];
    if (creator === undefined) throw new Error("leftover exceeds the number of creators");
    creator.payout += 1n;
  }

  return payouts;
}

/** Checks wallets (valid and unique, ignoring case) and scores (uint256). */
function validateCreators(creators: readonly CreatorScore[]): void {
  const seen = new Set<string>();
  for (const { wallet, score } of creators) {
    if (!isAddress(wallet, { strict: false })) throw new RangeError(`invalid wallet ${wallet}`);
    const key = wallet.toLowerCase();
    if (seen.has(key)) throw new RangeError(`duplicate wallet ${wallet}`);
    seen.add(key);
    assertUint256(score, `score of ${wallet}`);
  }
}

/** Three-way comparison of two bigints, for `Array.prototype.sort`. */
function compare(a: bigint, b: bigint): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
