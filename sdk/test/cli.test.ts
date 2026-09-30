import type { Hex } from "viem";
import { describe, expect, it } from "vitest";

import { type CliEnvironment, main } from "../src/cli.js";
import { hashCanonical, type OnChainCampaign } from "../src/index.js";
import { exampleDataset } from "./fixtures/example.js";

/** Runs the CLI against in-memory files and a fake chain. */
async function run(
  args: string[],
  files: Record<string, string>,
  chain?: { chainId: number; campaign: OnChainCampaign },
) {
  const out: string[] = [];
  const err: string[] = [];
  const env: CliEnvironment = {
    out: (line) => out.push(line),
    err: (line) => err.push(line),
    readFile: (path) => {
      const content = files[path];
      if (content === undefined) throw new Error("no such file");
      return content;
    },
    connect: () => ({
      chainId: async () => chain?.chainId ?? 0,
      readCampaign: async () => {
        if (chain === undefined) throw new Error("no chain");
        return chain.campaign;
      },
    }),
  };
  const code = await main(args, env);
  return { code, out: out.join("\n"), err: err.join("\n") };
}

const example = exampleDataset();
const files = { "result.json": JSON.stringify(example) };

function settledCampaign(): OnChainCampaign {
  const c = example.campaign;
  const t = example.totals;
  return {
    status: "Settled",
    brand: c.brand as Hex,
    token: c.token as Hex,
    budget: BigInt(c.budget),
    target: BigInt(c.target),
    startAt: BigInt(c.startAt),
    endAt: BigInt(c.endAt),
    manifestHash: c.manifestHash as Hex,
    recognized: BigInt(t.recognized),
    spent: BigInt(t.spent),
    fee: BigInt(t.fee),
    pool: BigInt(t.pool),
    refund: BigInt(t.refund),
    merkleRoot: example.merkle.root as Hex,
    resultHash: hashCanonical(example),
  };
}

describe("morcast-verify", () => {
  it("reports a valid dataset with exit code 0", async () => {
    const result = await run(["result.json"], files);
    expect(result.code).toBe(0);
    expect(result.out).toContain("Dataset      valid: 8 items, 5 creators, 4 payouts");
    expect(result.out).toContain(`resultHash   ${hashCanonical(example)}`);
  });

  it("lists every failed check with exit code 1", async () => {
    const broken = structuredClone(example);
    broken.totals.fee = "1";
    const result = await run(["result.json"], { "result.json": JSON.stringify(broken) });
    expect(result.code).toBe(1);
    expect(result.out).toContain("totals.fee: expected 12800000000");
  });

  it("prints a JSON report with --json", async () => {
    const result = await run(["result.json", "--json"], files);
    expect(JSON.parse(result.out)).toMatchObject({ valid: true, errors: [], onChain: null });
  });

  it("compares with the settled campaign with --rpc-url", async () => {
    const chain = { chainId: 31_337, campaign: settledCampaign() };
    const result = await run(["result.json", "--rpc-url", "http://rpc"], files, chain);
    expect(result.code).toBe(0);
    expect(result.out).toContain("On-chain     Settled; the dataset matches the campaign");
  });

  it("reports a different chain", async () => {
    const chain = { chainId: 8_453, campaign: settledCampaign() };
    const result = await run(["result.json", "--rpc-url", "http://rpc"], files, chain);
    expect(result.code).toBe(1);
    expect(result.out).toContain("chainId: the RPC endpoint serves chain 8453");
  });

  it.each([
    [[], "missing dataset file"],
    [["a.json", "b.json"], "unexpected argument b.json"],
    [["result.json", "--rpc-url"], "--rpc-url needs a value"],
    [["result.json", "--verbose"], "unknown option --verbose"],
    [["missing.json"], "cannot read missing.json"],
  ])("exits with 2 on %j", async (args, message) => {
    const result = await run(args, files);
    expect(result.code).toBe(2);
    expect(result.err).toContain(message);
  });
});
