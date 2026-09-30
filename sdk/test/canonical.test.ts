import { describe, expect, it } from "vitest";

import {
  type CanonicalValue,
  canonicalize,
  decimalString,
  hashCanonical,
  parseDecimalString,
} from "../src/index.js";
import { loadVectors } from "./helpers.js";

interface CanonicalVectors {
  cases: { name: string; value: CanonicalValue; canonical: string; hash: string }[];
}

describe("canonicalize", () => {
  const { cases } = loadVectors<CanonicalVectors>("canonical.json");

  it.each(cases)("matches vector $name", (c) => {
    expect(canonicalize(c.value)).toBe(c.canonical);
    expect(hashCanonical(c.value)).toBe(c.hash);
  });

  it("does not depend on the order in which members were inserted", () => {
    const a = { x: "1", y: { p: "2", q: ["3"] } };
    const b = { y: { q: ["3"], p: "2" }, x: "1" };
    expect(canonicalize(b)).toBe(canonicalize(a));
  });

  it.each([
    ["a number", { amount: 1 }],
    ["a bigint", { amount: 1n }],
    ["undefined", { amount: undefined }],
    ["a date", { at: new Date(0) }],
    ["an unpaired surrogate", { s: "\ud800" }],
    ["an unpaired surrogate in a key", { "\udc00": "x" }],
  ])("rejects %s", (_, value) => {
    expect(() => canonicalize(value as unknown as CanonicalValue)).toThrow(TypeError);
  });
});

describe("decimal strings", () => {
  it("round-trips integers", () => {
    for (const n of [0n, 1n, 1_000n, (1n << 256n) - 1n]) {
      expect(parseDecimalString(decimalString(n))).toBe(n);
    }
  });

  it.each(["", "-1", "01", "1.0", "1e3", " 1", "0x1"])("rejects %j", (value) => {
    expect(() => parseDecimalString(value)).toThrow(RangeError);
  });

  it("rejects negative integers", () => {
    expect(() => decimalString(-1n)).toThrow(RangeError);
  });
});
