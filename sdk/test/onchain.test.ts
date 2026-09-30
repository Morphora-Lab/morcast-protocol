import type { Hex } from "viem";
import { describe, expect, it } from "vitest";

import {
  compareWithChain,
  hashCanonical,
  type OnChainCampaign,
  readCampaign,
} from "../src/index.js";
import { exampleDataset } from "./fixtures/example.js";

const dataset = exampleDataset();
const resultHash = hashCanonical(dataset);

/** The on-chain state of the example campaign, funded or settled. */
function chainCampaign(status: OnChainCampaign["status"]): OnChainCampaign {
  const settled = status === "Settled";
  const c = dataset.campaign;
  const t = dataset.totals;
  const zero: Hex = `0x${"00".repeat(32)}`;
  return {
    status,
    brand: "0x90F79bf6EB2c4f870365E785982E1f101E93b906", // checksummed, as the chain returns it
    token: c.token as Hex,
    budget: BigInt(c.budget),
    target: BigInt(c.target),
    startAt: BigInt(c.startAt),
    endAt: BigInt(c.endAt),
    manifestHash: c.manifestHash as Hex,
    recognized: settled ? BigInt(t.recognized) : 0n,
    spent: settled ? BigInt(t.spent) : 0n,
    fee: settled ? BigInt(t.fee) : 0n,
    pool: settled ? BigInt(t.pool) : 0n,
    refund: settled ? BigInt(t.refund) : 0n,
    merkleRoot: settled ? (dataset.merkle.root as Hex) : zero,
    resultHash: settled ? resultHash : zero,
  };
}

describe("compareWithChain", () => {
  it("accepts a funded campaign with the same terms", () => {
    expect(compareWithChain(dataset, chainCampaign("Funded"), resultHash)).toEqual([]);
  });

  it("accepts the settled revision", () => {
    expect(compareWithChain(dataset, chainCampaign("Settled"), resultHash)).toEqual([]);
  });

  it("reports a revision other than the settled one", () => {
    const other: Hex = `0x${"22".repeat(32)}`;
    const errors = compareWithChain(dataset, chainCampaign("Settled"), other);
    expect(errors.map((e) => e.path)).toEqual(["resultHash"]);
  });

  it("reports different terms and settlement values", () => {
    const chain = { ...chainCampaign("Settled"), budget: 1n, recognized: 1n };
    const paths = compareWithChain(dataset, chain, resultHash).map((e) => e.path);
    expect(paths).toContain("campaign.budget");
    expect(paths).toContain("totals.recognized");
  });

  it("reports a campaign that does not exist", () => {
    const errors = compareWithChain(dataset, chainCampaign("None"), resultHash);
    expect(errors.map((e) => e.path)).toEqual(["campaignId"]);
  });
});

describe("readCampaign", () => {
  it("maps the contract struct", async () => {
    const onChain = chainCampaign("Settled");
    const client = {
      readContract: async () => ({
        ...onChain,
        status: 3,
        startAt: onChain.startAt,
        feePaid: false,
      }),
    };
    const campaign = await readCampaign(
      client as unknown as Parameters<typeof readCampaign>[0],
      dataset.escrow as Hex,
      1n,
    );
    expect(campaign.status).toBe("Settled");
    expect(campaign.budget).toBe(onChain.budget);
    expect(campaign.merkleRoot).toBe(onChain.merkleRoot);
  });
});
