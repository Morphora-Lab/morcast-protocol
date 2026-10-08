import { describe, expect, it } from "vitest";

import {
  allocatePayouts,
  buildPayoutTree,
  creatorScore,
  creatorThreshold,
  hashCanonical,
  recognizedTotal,
  split,
  verifyPayoutProof,
} from "../src/index.js";

/** Keeps the usage example in README.md correct. */
describe("README example", () => {
  it("produces the documented numbers", () => {
    const budget = 100_000_000_000n;
    const target = 1_000_000n;
    const threshold = creatorThreshold(target);
    expect(threshold).toBe(10_000n);

    const creators = [
      { wallet: "0x00000000000000000000000000000000000000c1", total: 300_000n },
      { wallet: "0x00000000000000000000000000000000000000c2", total: 180_000n },
      { wallet: "0x00000000000000000000000000000000000000c3", total: 9_000n },
    ] as const;

    const scores = creators.map((c) => ({
      wallet: c.wallet,
      score: creatorScore(c.total, threshold),
    }));
    const recognized = recognizedTotal(scores.map((s) => s.score));
    expect(recognized).toBe(480_000n);

    const { fee, pool, refund } = split(budget, target, recognized);
    expect([fee, pool, refund]).toEqual([9_600_000_000n, 38_400_000_000n, 52_000_000_000n]);

    const payouts = allocatePayouts(pool, scores);
    expect(payouts.map((p) => p.payout)).toEqual([24_000_000_000n, 14_400_000_000n, 0n]);

    // The zero payout is left out of the tree. Both remaining leaves have valid proofs.
    const tree = buildPayoutTree(
      1n,
      payouts.map((p) => ({ wallet: p.wallet, amount: p.payout })),
    );
    expect(tree.leaves).toHaveLength(2);
    for (const leaf of tree.leaves) {
      expect(verifyPayoutProof(tree.root, 1n, leaf.wallet, leaf.amount, leaf.proof)).toBe(true);
    }
    expect(hashCanonical({ campaignId: "1", status: "PASS" })).toMatch(/^0x[0-9a-f]{64}$/);
  });
});
