import type { Address } from "viem";
import { describe, expect, it } from "vitest";

import { allocatePayouts } from "../src/index.js";
import { loadVectors, Random } from "./helpers.js";

interface PayoutVectors {
  cases: {
    name: string;
    pool: string;
    creators: { wallet: Address; score: string; payout: string }[];
  }[];
}

/** Wallet with the given numeric value, e.g. wallet(1) = 0x00…01. */
function wallet(n: number): Address {
  return `0x${n.toString(16).padStart(40, "0")}`;
}

describe("allocatePayouts", () => {
  const { cases } = loadVectors<PayoutVectors>("payouts.json");

  it.each(cases)("matches vector $name", (c) => {
    const result = allocatePayouts(
      BigInt(c.pool),
      c.creators.map(({ wallet, score }) => ({ wallet, score: BigInt(score) })),
    );
    expect(result.map((r) => r.payout)).toEqual(c.creators.map((x) => BigInt(x.payout)));
  });

  it("keeps the input order and the creator fields", () => {
    const result = allocatePayouts(10n, [
      { wallet: wallet(2), score: 1n },
      { wallet: wallet(1), score: 1n },
    ]);
    expect(result).toEqual([
      { wallet: wallet(2), score: 1n, payout: 5n },
      { wallet: wallet(1), score: 1n, payout: 5n },
    ]);
  });

  it("pays zero-score creators nothing and never gives them leftover units", () => {
    const result = allocatePayouts(10n, [
      { wallet: wallet(1), score: 0n },
      { wallet: wallet(2), score: 1n },
      { wallet: wallet(3), score: 2n },
    ]);
    expect(result.map((r) => r.payout)).toEqual([0n, 3n, 7n]);
  });

  it("pays nothing when no creator scores", () => {
    const result = allocatePayouts(1_000n, [{ wallet: wallet(1), score: 0n }]);
    expect(result[0]?.payout).toBe(0n);
  });

  it("distributes exactly the pool, within one unit of each exact share", () => {
    const random = new Random(2026n);
    for (let i = 0; i < 1_000; i++) {
      const pool = random.bits(128);
      const creators = Array.from({ length: Number(random.between(1n, 12n)) }, (_, n) => ({
        wallet: wallet(n + 1),
        score: random.between(0n, 1n << 80n),
      }));
      const total = creators.reduce((sum, c) => sum + c.score, 0n);
      const result = allocatePayouts(pool, creators);

      const paid = result.reduce((sum, r) => sum + r.payout, 0n);
      expect(paid).toBe(total === 0n ? 0n : pool);
      for (const r of result) {
        const exact = total === 0n ? 0n : (pool * r.score) / total;
        expect(r.payout === exact || r.payout === exact + 1n).toBe(true);
      }
    }
  });

  it("rejects duplicate wallets regardless of case, and invalid input", () => {
    const upper = "0x00000000000000000000000000000000000000AB" as Address;
    const lower = "0x00000000000000000000000000000000000000ab" as Address;
    expect(() =>
      allocatePayouts(10n, [
        { wallet: upper, score: 1n },
        { wallet: lower, score: 1n },
      ]),
    ).toThrow(/duplicate/);
    expect(() => allocatePayouts(10n, [{ wallet: "0x1234" as Address, score: 1n }])).toThrow(
      /invalid wallet/,
    );
    expect(() => allocatePayouts(10n, [{ wallet: wallet(1), score: -1n }])).toThrow(RangeError);
    expect(() => allocatePayouts(-1n, [])).toThrow(RangeError);
  });
});
