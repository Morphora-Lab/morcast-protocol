import { readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import {
  type DatasetCreator,
  type DatasetItem,
  hashCanonical,
  type ResultDataset,
  verifyResultDataset,
} from "../src/index.js";
import { exampleDataset } from "./fixtures/example.js";

const EXAMPLE_FILE = new URL("../../examples/result-dataset.json", import.meta.url);

/** Item `index` of a dataset built from the example, which always has it. */
function itemAt(d: ResultDataset, index: number): DatasetItem {
  const item = d.items[index];
  if (item === undefined) throw new Error(`no item ${index}`);
  return item;
}

/** Creator `index` of a dataset built from the example, which always has it. */
function creatorAt(d: ResultDataset, index: number): DatasetCreator {
  const creator = d.creators[index];
  if (creator === undefined) throw new Error(`no creator ${index}`);
  return creator;
}

describe("example dataset", () => {
  it("matches examples/result-dataset.json (UPDATE_EXAMPLES=1 rewrites it)", () => {
    const text = `${JSON.stringify(exampleDataset(), null, 2)}\n`;
    if (process.env.UPDATE_EXAMPLES === "1") writeFileSync(EXAMPLE_FILE, text);
    expect(readFileSync(EXAMPLE_FILE, "utf8")).toBe(text);
  });

  it("passes every check", () => {
    const report = verifyResultDataset(exampleDataset());
    expect(report.errors).toEqual([]);
    expect(report.valid).toBe(true);
    expect(report.resultHash).toBe(hashCanonical(exampleDataset()));
  });

  it("reproduces the specification's partial-delivery numbers", () => {
    const d = exampleDataset();
    expect(d.totals).toEqual({
      recognized: "640000",
      spent: "64000000000",
      fee: "12800000000",
      pool: "51200000000",
      refund: "36000000000",
    });
    expect(d.creators.map((c) => c.payout)).toEqual([
      "24000000000",
      "14400000000",
      "9600000000",
      "3200000000",
      "0",
    ]);
    expect(d.merkle.leaves).toHaveLength(4);
  });
});

describe("verifyResultDataset", () => {
  const otherHash = `0x${"11".repeat(32)}`;
  const cases: [string, (d: ResultDataset) => void, string][] = [
    [
      "a wrong threshold",
      (d) => {
        d.campaign.threshold = "9999";
      },
      "campaign.threshold",
    ],
    [
      "a budget that is not a multiple of 5",
      (d) => {
        d.campaign.budget = "101";
      },
      "campaign.budget",
    ],
    [
      "an empty campaign window",
      (d) => {
        d.campaign.startAt = d.campaign.endAt;
      },
      "campaign.endAt",
    ],
    [
      "a format on an X campaign",
      (d) => {
        d.campaign.platform = "X";
      },
      "campaign.format",
    ],
    [
      "a publication before the end",
      (d) => {
        d.publishedAt = d.campaign.startAt;
      },
      "publishedAt",
    ],
    [
      "a previous hash on revision 0",
      (d) => {
        d.previousResultHash = otherHash;
      },
      "previousResultHash",
    ],
    [
      "a revision without a previous hash",
      (d) => {
        d.revision = "1";
      },
      "previousResultHash",
    ],
    [
      "issues in revision 0",
      (d) => {
        d.issues.push({
          issueId: "iss-1",
          raisedBy: d.campaign.brand,
          raisedAt: d.publishedAt,
          submissionId: null,
          summary: "Recount requested",
          outcome: "REJECTED",
          decision: "Counts confirmed",
          decidedAt: d.publishedAt,
        });
      },
      "issues",
    ],
    [
      "items out of order",
      (d) => {
        d.items.reverse();
      },
      "items[1]",
    ],
    [
      "a duplicate submission ID",
      (d) => {
        itemAt(d, 1).submissionId = "sub-0001";
      },
      "items[1].submissionId",
    ],
    [
      "a submission received after endAt",
      (d) => {
        itemAt(d, 7).receivedAt = d.campaign.endAt;
      },
      "items[7].receivedAt",
    ],
    [
      "a FAIL item with a metric",
      (d) => {
        itemAt(d, 3).metric = "5";
      },
      "items[3].metric",
    ],
    [
      "a PASS item with reasons",
      (d) => {
        itemAt(d, 0).reasons = ["EDITED"];
      },
      "items[0].reasons",
    ],
    [
      "a primary reason that is not listed",
      (d) => {
        itemAt(d, 6).primaryReason = "EDITED";
      },
      "items[6].primaryReason",
    ],
    [
      "unsorted reasons",
      (d) => {
        itemAt(d, 7).reasons = ["NOT_PUBLIC", "FRAUD"];
      },
      "items[7].reasons",
    ],
    [
      "the same content counted twice",
      (d) => {
        Object.assign(itemAt(d, 3), {
          status: "PASS",
          reasons: [],
          primaryReason: null,
          metric: "1",
        });
      },
      "items[3].contentId",
    ],
    [
      "one account paired with two wallets",
      (d) => {
        itemAt(d, 1).account = itemAt(d, 0).account;
      },
      "items[1]",
    ],
    [
      "retention evidence outside an Integration campaign",
      (d) => {
        itemAt(d, 0).integration = {
          views: "600000",
          segmentStartSec: "10",
          segmentEndSec: "40",
          durationSec: "600",
          retention: "500000",
        };
      },
      "items[0].integration",
    ],
    [
      "a missing creator",
      (d) => {
        d.creators.pop();
      },
      "creators",
    ],
    [
      "a wrong creator total",
      (d) => {
        creatorAt(d, 0).total = "1";
      },
      "creators[0].total",
    ],
    [
      "a wrong creator score",
      (d) => {
        creatorAt(d, 4).score = "9000";
      },
      "creators[4].score",
    ],
    [
      "a wrong creator account",
      (d) => {
        creatorAt(d, 0).account = "UCsomeoneElse123456789ab";
      },
      "creators[0].account",
    ],
    [
      "a wrong recognized total",
      (d) => {
        d.totals.recognized = "640001";
      },
      "totals.recognized",
    ],
    [
      "a wrong fee",
      (d) => {
        d.totals.fee = "1";
      },
      "totals.fee",
    ],
    [
      "a wrong refund",
      (d) => {
        d.totals.refund = "0";
      },
      "totals.refund",
    ],
    [
      "a wrong payout",
      (d) => {
        creatorAt(d, 1).payout = "14399999999";
      },
      "creators[1].payout",
    ],
    [
      "a missing leaf",
      (d) => {
        d.merkle.leaves.pop();
      },
      "merkle.leaves",
    ],
    [
      "a wrong root",
      (d) => {
        d.merkle.root = otherHash;
      },
      "merkle.root",
    ],
  ];

  it.each(cases)("reports %s", (_, mutate, path) => {
    const dataset = structuredClone(exampleDataset());
    mutate(dataset);
    const report = verifyResultDataset(dataset);
    expect(report.valid).toBe(false);
    expect(report.errors.map((e) => e.path)).toContain(path);
  });

  it("reports schema violations with their paths", () => {
    const withNumber = structuredClone(exampleDataset()) as unknown as Record<string, unknown>;
    (withNumber.totals as Record<string, unknown>).fee = 12_800_000_000;
    const report = verifyResultDataset(withNumber);
    expect(report.valid).toBe(false);
    expect(report.resultHash).toBeNull(); // JSON numbers are not canonical
    expect(report.errors.map((e) => e.path)).toContain("totals.fee");

    const upperCase = structuredClone(exampleDataset());
    upperCase.campaign.brand = upperCase.campaign.brand.toUpperCase().replace("0X", "0x");
    expect(verifyResultDataset(upperCase).errors.map((e) => e.path)).toContain("campaign.brand");

    const extra = { ...structuredClone(exampleDataset()), note: "extra" };
    expect(verifyResultDataset(extra).valid).toBe(false);
  });

  it("accepts a later revision with issues", () => {
    const d = structuredClone(exampleDataset());
    d.revision = "1";
    d.previousResultHash = hashCanonical(exampleDataset());
    d.issues.push({
      issueId: "iss-1",
      raisedBy: d.creators[4]?.wallet ?? d.campaign.brand,
      raisedAt: d.publishedAt,
      submissionId: "sub-0006",
      summary: "Views below the threshold; recount requested",
      outcome: "REJECTED",
      decision: "Counts confirmed against YouTube Analytics",
      decidedAt: d.publishedAt,
    });
    expect(verifyResultDataset(d).errors).toEqual([]);
  });
});

describe("Integration campaigns", () => {
  /** The example as an Integration campaign: every PASS item watched at 50% retention. */
  function integrationDataset(): ResultDataset {
    const d = structuredClone(exampleDataset());
    d.campaign.format = "INTEGRATION";
    for (const item of d.items) {
      if (item.status !== "PASS") continue;
      item.integration = {
        views: (BigInt(item.metric) * 2n).toString(),
        segmentStartSec: "30",
        segmentEndSec: "75",
        durationSec: "600",
        retention: "500000",
      };
    }
    return d;
  }

  it("accepts metrics equal to views x retention / 1,000,000", () => {
    expect(verifyResultDataset(integrationDataset()).errors).toEqual([]);
  });

  it.each<[string, (evidence: Record<string, string>) => void, string]>([
    [
      "a metric that does not match",
      (e) => {
        e.views = "1";
      },
      "items[0].metric",
    ],
    [
      "a retention above 100%",
      (e) => {
        e.retention = "1000001";
      },
      "items[0].integration.retention",
    ],
    [
      "a segment past the end of the video",
      (e) => {
        e.segmentEndSec = "601";
      },
      "items[0].integration",
    ],
  ])("reports %s", (_, mutate, path) => {
    const d = integrationDataset();
    mutate(itemAt(d, 0).integration as unknown as Record<string, string>);
    expect(verifyResultDataset(d).errors.map((e) => e.path)).toContain(path);
  });

  it("requires retention evidence on PASS items", () => {
    const d = integrationDataset();
    itemAt(d, 0).integration = null;
    expect(verifyResultDataset(d).errors.map((e) => e.path)).toContain("items[0].integration");
  });
});
