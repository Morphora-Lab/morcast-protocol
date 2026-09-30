import { describe, expect, it } from "vitest";

import { integrationMetric, type RetentionSample, retentionFactor, trunc6 } from "../src/index.js";
import { loadVectors } from "./helpers.js";

interface MetricVectors {
  trunc6: { input: string; output: string }[];
  retention: {
    name: string;
    segmentStartSec: string;
    segmentEndSec: string;
    durationSec: string;
    samples: RetentionSample[];
    retention: string | null;
  }[];
  integration: { name: string; views: string; retention: string; metric: string }[];
}

const vectors = loadVectors<MetricVectors>("metrics.json");

describe("trunc6", () => {
  it.each(vectors.trunc6)("truncates $input", ({ input, output }) => {
    expect(trunc6(input)).toBe(BigInt(output));
  });

  it.each(["-0.5", "abc", ".5", "1.", "01", "", "1e", "0x10"])("rejects %j", (input) => {
    expect(() => trunc6(input)).toThrow(RangeError);
  });
});

describe("retentionFactor", () => {
  it.each(vectors.retention)("matches vector $name", (c) => {
    const result = retentionFactor(
      c.samples,
      BigInt(c.segmentStartSec),
      BigInt(c.segmentEndSec),
      BigInt(c.durationSec),
    );
    expect(result).toBe(c.retention === null ? null : BigInt(c.retention));
  });

  it("rejects a segment outside the video", () => {
    const samples = [{ position: "0.5", ratio: "0.9" }];
    expect(() => retentionFactor(samples, 10n, 10n, 100n)).toThrow(RangeError);
    expect(() => retentionFactor(samples, 20n, 10n, 100n)).toThrow(RangeError);
    expect(() => retentionFactor(samples, 90n, 101n, 100n)).toThrow(RangeError);
    expect(() => retentionFactor(samples, -1n, 10n, 100n)).toThrow(RangeError);
  });
});

describe("integrationMetric", () => {
  it.each(vectors.integration)("matches vector $name", (c) => {
    expect(integrationMetric(BigInt(c.views), BigInt(c.retention))).toBe(BigInt(c.metric));
  });

  it("rejects a retention above 100%", () => {
    expect(() => integrationMetric(100n, 1_000_001n)).toThrow(RangeError);
  });
});
