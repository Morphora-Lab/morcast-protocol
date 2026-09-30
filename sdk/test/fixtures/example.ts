import type { Address } from "viem";

import {
  allocatePayouts,
  buildPayoutTree,
  creatorScore,
  creatorThreshold,
  type DatasetItem,
  hashCanonical,
  RESULT_SCHEMA,
  type ResultDataset,
  split,
} from "../../src/index.js";

/**
 * The example result dataset in examples/result-dataset.json, built from its inputs with the
 * SDK: a YouTube DEDICATED campaign with the specification's partial-delivery numbers, deployed
 * on a local Anvil node with script/DeployLocal.s.sol.
 */
export function exampleDataset(): ResultDataset {
  const startAt = 1_790_838_000n; // 2026-10-01 00:00 America/Los_Angeles
  const endAt = 1_792_047_600n; // 2026-10-15 00:00 America/Los_Angeles
  const day = (n: bigint) => endAt + n * 86_400n;
  const budget = 100_000_000_000n; // 100,000 USDC
  const target = 1_000_000n;
  const threshold = creatorThreshold(target);

  const wallets = {
    a: "0x14dc79964da2c08b23698b3d3cc7ca32193d9955",
    b: "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65",
    c: "0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f",
    d: "0x976ea74026e726554db657fa54763abd0c3a0aa9",
    e: "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc",
  } as const;
  const channels = {
    a: "UCa4Vq1kP8sZ2xN7mR3tY6wB",
    b: "UCb9Lm2nQ5rT8vX1yZ4cD7eF",
    c: "UCc3Hj6kL9mN2pQ5rS8tU1vW",
    d: "UCd7Fg1hJ4kL7mN0pQ3rS6tU",
    e: "UCe2Xy5zA8bC1dE4fG7hJ0kL",
  } as const;

  type Creator = keyof typeof wallets;
  const item = (
    index: number,
    creator: Creator,
    video: string,
    received: bigint,
    outcome: { metric: bigint } | { reasons: string[]; primary: string; measured: boolean },
  ): DatasetItem => {
    const submissionId = `sub-${String(index).padStart(4, "0")}`;
    const passed = "metric" in outcome;
    return {
      submissionId,
      wallet: wallets[creator],
      account: channels[creator],
      contentId: video,
      contentUrl: `https://www.youtube.com/watch?v=${video}`,
      receivedAt: received.toString(),
      status: passed ? "PASS" : "FAIL",
      reasons: passed ? [] : outcome.reasons,
      primaryReason: passed ? null : outcome.primary,
      metric: passed ? outcome.metric.toString() : "0",
      retrievedAt: passed || outcome.measured ? (day(3n) + 3_600n).toString() : null,
      evidence: `https://evidence.morcast.example/campaigns/1/${submissionId}`,
      integration: null,
    };
  };

  const h = 3_600n;
  const items: DatasetItem[] = [
    item(1, "a", "Xk2mP4vL8qR", startAt + 48n * h, { metric: 300_000n }),
    item(2, "b", "Ld7Nq2wE5tY", startAt + 72n * h, { metric: 180_000n }),
    item(3, "c", "Pz9Rt3uI6oA", startAt + 96n * h, { metric: 120_000n }),
    item(4, "a", "Hy5Tq8wZ3nB", startAt + 120n * h, {
      reasons: ["EDITED"],
      primary: "EDITED",
      measured: true,
    }),
    item(5, "d", "Bn4Mv7cX1zS", startAt + 144n * h, { metric: 40_000n }),
    item(6, "e", "Qw8Er5tY2uI", startAt + 168n * h, { metric: 9_000n }),
    item(7, "b", "Gh3Jk6lZ9xC", startAt + 192n * h, {
      reasons: ["NOT_PUBLIC"],
      primary: "NOT_PUBLIC",
      measured: true,
    }),
    item(8, "d", "Vb2Nm5aS8dF", startAt + 216n * h, {
      reasons: ["FRAUD", "NOT_PUBLIC"],
      primary: "FRAUD",
      measured: true,
    }),
  ];

  // Creators in wallet order, with totals over PASS items and scores.
  const creators = (Object.keys(wallets) as Creator[])
    .map((key) => {
      const total = items
        .filter((it) => it.wallet === wallets[key] && it.status === "PASS")
        .reduce((sum, it) => sum + BigInt(it.metric), 0n);
      return { key, wallet: wallets[key] as Address, total, score: creatorScore(total, threshold) };
    })
    .sort((x, y) => (x.wallet < y.wallet ? -1 : 1));

  const recognized = creators.reduce((sum, c) => sum + c.score, 0n);
  const totals = split(budget, target, recognized);
  const payouts = allocatePayouts(totals.pool, creators);
  const leaves = payouts.filter((p) => p.payout > 0n);
  const tree = buildPayoutTree(
    1n,
    leaves.map((p) => ({ wallet: p.wallet, amount: p.payout })),
  );

  return {
    schema: RESULT_SCHEMA,
    chainId: "31337",
    escrow: "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0",
    campaignId: "1",
    revision: "0",
    previousResultHash: null,
    publishedAt: (day(3n) + 6n * h).toString(),
    campaign: {
      manifestHash: hashCanonical({ name: "Example DEDICATED campaign" }),
      brand: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
      token: "0x5fbdb2315678afecb367f032d93f642f64180aa3",
      platform: "YOUTUBE",
      format: "DEDICATED",
      budget: budget.toString(),
      target: target.toString(),
      threshold: threshold.toString(),
      startAt: startAt.toString(),
      endAt: endAt.toString(),
    },
    items,
    creators: creators.map((c, i) => ({
      wallet: c.wallet,
      account: channels[c.key],
      total: c.total.toString(),
      score: c.score.toString(),
      payout: (payouts[i]?.payout ?? 0n).toString(),
    })),
    totals: {
      recognized: recognized.toString(),
      spent: totals.spent.toString(),
      fee: totals.fee.toString(),
      pool: totals.pool.toString(),
      refund: totals.refund.toString(),
    },
    merkle: {
      root: tree.root,
      leaves: tree.leaves.map((l) => ({ wallet: l.wallet, amount: l.amount.toString() })),
    },
    issues: [],
  };
}
