import { describe, expect, it } from "vitest";

import {
  creatorScore,
  creatorThreshold,
  MAX_UINT256,
  recognizedTotal,
  split,
} from "../src/index.js";
import { loadVectors, Random } from "./helpers.js";

interface SettlementVectors {
  cases: {
    name: string;
    budget: string;
    target: string;
    recognized: string;
    spent: string;
    fee: string;
    pool: string;
    refund: string;
  }[];
}

describe("split", () => {
  const { cases } = loadVectors<SettlementVectors>("settlement.json");

  it.each(cases)("matches vector $name", (c) => {
    expect(split(BigInt(c.budget), BigInt(c.target), BigInt(c.recognized))).toEqual({
      spent: BigInt(c.spent),
      fee: BigInt(c.fee),
      pool: BigInt(c.pool),
      refund: BigInt(c.refund),
    });
  });

  it("conserves the budget and splits 20/80 for random inputs", () => {
    const random = new Random(42n);
    for (let i = 0; i < 2_000; i++) {
      const budget = random.bits(256);
      const target = random.between(1n, MAX_UINT256);
      const recognized = random.bits(256);
      const { spent, fee, pool, refund } = split(budget, target, recognized);

      expect(fee + pool + refund).toBe(budget);
      expect(spent % 5n).toBe(0n);
      expect(pool).toBe(4n * fee);
      expect(spent <= budget).toBe(true);
    }
  });

  it("spends the whole budget once the target is reached", () => {
    const random = new Random(7n);
    for (let i = 0; i < 500; i++) {
      const budget = random.between(1n, MAX_UINT256 / 5n) * 5n;
      const target = random.between(1n, MAX_UINT256);
      const recognized = random.between(target, MAX_UINT256);
      expect(split(budget, target, recognized).spent).toBe(budget);
    }
  });

  it("rejects a zero target and values outside uint256", () => {
    expect(() => split(100n, 0n, 1n)).toThrow(RangeError);
    expect(() => split(-5n, 1n, 1n)).toThrow(RangeError);
    expect(() => split(MAX_UINT256 + 1n, 1n, 1n)).toThrow(RangeError);
  });
});

describe("creator scoring", () => {
  it("computes the threshold M = ceil(T / 100)", () => {
    expect(creatorThreshold(1_000_000n)).toBe(10_000n);
    expect(creatorThreshold(3_000n)).toBe(30n);
    expect(creatorThreshold(101n)).toBe(2n);
    expect(creatorThreshold(100n)).toBe(1n);
    expect(creatorThreshold(1n)).toBe(1n);
    expect(() => creatorThreshold(0n)).toThrow(RangeError);
  });

  it("scores zero below the threshold and the full total at or above it", () => {
    expect(creatorScore(9_999n, 10_000n)).toBe(0n);
    expect(creatorScore(10_000n, 10_000n)).toBe(10_000n);
    expect(creatorScore(300_000n, 10_000n)).toBe(300_000n);
  });

  it("reproduces the specification's partial-delivery example", () => {
    // T = 1,000,000 so M = 10,000; the creator with 9,000 scores zero.
    const threshold = creatorThreshold(1_000_000n);
    const totals = [300_000n, 180_000n, 120_000n, 40_000n, 9_000n];
    const scores = totals.map((total) => creatorScore(total, threshold));

    expect(scores).toEqual([300_000n, 180_000n, 120_000n, 40_000n, 0n]);
    expect(recognizedTotal(scores)).toBe(640_000n);
  });

  it("reproduces the specification's threshold example", () => {
    // 100 creators just below M. Nothing is recognized.
    const scores = Array.from({ length: 100 }, () => creatorScore(9_999n, 10_000n));
    expect(recognizedTotal(scores)).toBe(0n);
  });
});
