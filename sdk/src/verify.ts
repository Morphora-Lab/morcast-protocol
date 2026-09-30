/**
 * Independent verification of a published result dataset.
 *
 * Anyone can run these checks on a dataset: its structure, every derived value (creator totals,
 * scores, settlement totals, payouts, Merkle leaves and root) and its internal consistency.
 * The measurements themselves (metrics, statuses) are MORCast's responsibility and are taken as
 * published; everything computed from them is recomputed here.
 */

import type { Hex } from "viem";

import { type CanonicalValue, hashCanonical, parseDecimalString } from "./canonical.js";
import { MAX_CAMPAIGN_DURATION } from "./constants.js";
import {
  type DatasetCreator,
  type DatasetItem,
  type ResultDataset,
  resultDatasetSchema,
} from "./dataset.js";
import { buildPayoutTree } from "./merkle.js";
import { integrationMetric, RETENTION_SCALE } from "./metrics.js";
import { allocatePayouts } from "./payouts.js";
import { creatorScore, creatorThreshold, split } from "./settlement.js";

/** One failed check. `path` points into the dataset, e.g. `items[3].metric`. */
export interface VerificationError {
  path: string;
  message: string;
}

/** Outcome of {@link verifyResultDataset}. */
export interface VerificationReport {
  /** True when every check passed. */
  valid: boolean;
  /** keccak256 of the canonical dataset, or null if the input is not a canonical document. */
  resultHash: Hex | null;
  /** Every failed check; empty when valid. */
  errors: VerificationError[];
  /** The typed dataset, when the input matches the schema. */
  dataset: ResultDataset | null;
}

/**
 * Verifies a result dataset (for example, `JSON.parse` of the published file).
 *
 * @example
 * const report = verifyResultDataset(JSON.parse(readFileSync("result.json", "utf8")));
 * if (!report.valid) console.error(report.errors);
 */
export function verifyResultDataset(input: unknown): VerificationReport {
  const resultHash = tryHash(input);
  const parsed = resultDatasetSchema.safeParse(input);
  if (!parsed.success) {
    return {
      valid: false,
      resultHash,
      dataset: null,
      errors: parsed.error.issues.map((issue) => ({
        path: formatPath(issue.path),
        message: issue.message,
      })),
    };
  }

  const dataset = parsed.data;
  const errors: VerificationError[] = [];
  const fail = (path: string, message: string) => errors.push({ path, message });

  checkHeader(dataset, fail);
  checkItems(dataset, fail);
  const creatorsValid = checkCreators(dataset, fail);
  checkTotalsAndMerkle(dataset, creatorsValid, fail);
  checkIssues(dataset, fail);

  return { valid: errors.length === 0, resultHash, errors, dataset };
}

type Fail = (path: string, message: string) => void;

// ---------------------------------------------------------------------------------------------
// Header and campaign terms
// ---------------------------------------------------------------------------------------------

function checkHeader(d: ResultDataset, fail: Fail): void {
  const c = d.campaign;
  const budget = n(c.budget);
  const target = n(c.target);

  if (n(d.campaignId) === 0n) fail("campaignId", "campaign IDs start at 1");
  if ((n(d.revision) === 0n) !== (d.previousResultHash === null)) {
    fail("previousResultHash", "must be null exactly when revision is 0");
  }
  // Issues are raised after the first publication, so they appear from revision 1 on.
  if (n(d.revision) === 0n && d.issues.length > 0) {
    fail("issues", "revision 0 is the first publication and cannot contain issues");
  }
  if (budget === 0n || budget % 5n !== 0n) {
    fail("campaign.budget", "must be positive and a multiple of 5");
  }
  if (target === 0n) {
    fail("campaign.target", "must be positive");
  } else if (n(c.threshold) !== creatorThreshold(target)) {
    fail("campaign.threshold", `expected ceil(target / 100) = ${creatorThreshold(target)}`);
  }
  if (n(c.startAt) >= n(c.endAt)) {
    fail("campaign.endAt", "must be after startAt");
  } else if (n(c.endAt) - n(c.startAt) > MAX_CAMPAIGN_DURATION) {
    fail("campaign.endAt", "the campaign must not last longer than 90 days");
  }
  if (n(d.publishedAt) < n(c.endAt)) fail("publishedAt", "must not be before the campaign ends");
  if ((c.platform === "X") !== (c.format === null)) {
    fail("campaign.format", "must be null for X and DEDICATED or INTEGRATION for YOUTUBE");
  }
}

// ---------------------------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------------------------

function checkItems(d: ResultDataset, fail: Fail): void {
  const integration = d.campaign.format === "INTEGRATION";
  const submissionIds = new Set<string>();
  const passedContent = new Map<string, number>();
  const accountOfWallet = new Map<string, string>();
  const walletOfAccount = new Map<string, string>();

  d.items.forEach((item, i) => {
    const path = `items[${i}]`;
    const previous = d.items[i - 1];

    // Order: receive time, then submission ID. Submission IDs are unique.
    if (previous !== undefined && !itemBefore(previous, item)) {
      fail(path, "items must be ordered by receivedAt, then submissionId");
    }
    if (submissionIds.has(item.submissionId)) fail(`${path}.submissionId`, "duplicate");
    submissionIds.add(item.submissionId);

    if (n(item.receivedAt) >= n(d.campaign.endAt)) {
      fail(`${path}.receivedAt`, "submissions must be received before endAt");
    }
    if (!strictlySorted(item.reasons)) fail(`${path}.reasons`, "must be sorted and unique");

    if (item.status === "PASS") {
      if (item.reasons.length > 0) fail(`${path}.reasons`, "must be empty for PASS");
      if (item.primaryReason !== null) fail(`${path}.primaryReason`, "must be null for PASS");

      // Each content ID counts once.
      const first = passedContent.get(item.contentId);
      if (first !== undefined) {
        fail(`${path}.contentId`, `already counted in items[${first}]`);
      } else {
        passedContent.set(item.contentId, i);
      }

      // Within a campaign, one wallet uses one account and one account one wallet.
      const account = accountOfWallet.get(item.wallet) ?? item.account;
      const wallet = walletOfAccount.get(item.account) ?? item.wallet;
      if (account !== item.account || wallet !== item.wallet) {
        fail(path, "a wallet and an account must be paired one to one");
      }
      accountOfWallet.set(item.wallet, account);
      walletOfAccount.set(item.account, wallet);
    } else {
      if (item.reasons.length === 0) fail(`${path}.reasons`, "must not be empty for FAIL");
      if (item.primaryReason === null || !item.reasons.includes(item.primaryReason)) {
        fail(`${path}.primaryReason`, "must be one of the reasons");
      }
      if (n(item.metric) !== 0n) fail(`${path}.metric`, "must be 0 for FAIL");
    }

    if (!integration) {
      if (item.integration !== null) {
        fail(`${path}.integration`, "only Integration campaigns have retention evidence");
      }
    } else if (item.status === "PASS") {
      checkIntegration(item, path, fail);
    }
  });
}

/** A PASS Integration item: valid segment and retention, and q = V × R_u div 1,000,000. */
function checkIntegration(item: DatasetItem, path: string, fail: Fail): void {
  const evidence = item.integration;
  if (evidence === null) {
    fail(`${path}.integration`, "required for a PASS Integration item");
    return;
  }
  const start = n(evidence.segmentStartSec);
  const end = n(evidence.segmentEndSec);
  if (start >= end || end > n(evidence.durationSec)) {
    fail(`${path}.integration`, "segment must satisfy start < end <= duration");
  }
  const retention = n(evidence.retention);
  if (retention > RETENTION_SCALE) {
    fail(`${path}.integration.retention`, `must not exceed ${RETENTION_SCALE}`);
    return;
  }
  const expected = integrationMetric(n(evidence.views), retention);
  if (n(item.metric) !== expected) {
    fail(`${path}.metric`, `expected views x retention / 1000000 = ${expected}`);
  }
}

// ---------------------------------------------------------------------------------------------
// Creators
// ---------------------------------------------------------------------------------------------

/**
 * Checks the creator list. Returns false when the list itself is unusable (wrong wallets, order or
 * duplicates, or a wallet that can never be paid), in which case payouts are not recomputed.
 */
function checkCreators(d: ResultDataset, fail: Fail): boolean {
  let valid = true;

  // A payout to the zero address or to the escrow itself could never leave the escrow.
  d.creators.forEach((creator, i) => {
    if (BigInt(creator.wallet) === 0n || creator.wallet === d.escrow) {
      fail(`creators[${i}].wallet`, "must not be the zero address or the escrow contract");
      valid = false;
    }
  });

  // Expected: one creator per wallet with an item, ordered by wallet address.
  const wallets = [...new Set(d.items.map((item) => item.wallet))].sort();
  const listed = d.creators.map((creator) => creator.wallet);
  if (wallets.join() !== listed.join()) {
    fail("creators", "must list each wallet with an item exactly once, ordered by address");
    return false;
  }

  const threshold = n(d.campaign.threshold);
  d.creators.forEach((creator, i) => {
    const path = `creators[${i}]`;
    const passed = d.items.filter((it) => it.wallet === creator.wallet && it.status === "PASS");

    const total = passed.reduce((sum, item) => sum + n(item.metric), 0n);
    if (n(creator.total) !== total) fail(`${path}.total`, `expected ${total}`);

    const score = creatorScore(total, threshold);
    if (n(creator.score) !== score) fail(`${path}.score`, `expected ${score}`);

    const account = passed[0]?.account;
    if (account !== undefined && creator.account !== account) {
      fail(`${path}.account`, `expected ${account}, the account of its PASS items`);
    }
  });
  return valid;
}

// ---------------------------------------------------------------------------------------------
// Totals, payouts and Merkle tree
// ---------------------------------------------------------------------------------------------

function checkTotalsAndMerkle(d: ResultDataset, creatorsValid: boolean, fail: Fail): void {
  const recognized = d.creators.reduce((sum, creator) => sum + n(creator.score), 0n);
  if (n(d.totals.recognized) !== recognized) {
    fail("totals.recognized", `expected the sum of scores, ${recognized}`);
  }

  const budget = n(d.campaign.budget);
  const target = n(d.campaign.target);
  if (target === 0n) return; // already reported

  const expected = split(budget, target, recognized);
  for (const key of ["spent", "fee", "pool", "refund"] as const) {
    if (n(d.totals[key]) !== expected[key]) fail(`totals.${key}`, `expected ${expected[key]}`);
  }

  // Payouts and leaves are only recomputed over a valid creator list (errors already reported).
  if (!creatorsValid) return;

  // Payouts follow the allocation rule over the creators' scores.
  const payouts = allocatePayouts(
    expected.pool,
    d.creators.map((creator) => ({ wallet: creator.wallet as Hex, score: n(creator.score) })),
  );
  d.creators.forEach((creator: DatasetCreator, i) => {
    const payout = payouts[i]?.payout ?? 0n;
    if (n(creator.payout) !== payout) fail(`creators[${i}].payout`, `expected ${payout}`);
  });

  // Leaves: every non-zero payout, in wallet order; root: the payout tree over those leaves.
  const leaves = d.creators
    .filter((creator) => n(creator.payout) > 0n)
    .map((creator) => ({ wallet: creator.wallet, amount: creator.payout }));
  const sameLeaves =
    leaves.length === d.merkle.leaves.length &&
    leaves.every(
      (leaf, i) =>
        leaf.wallet === d.merkle.leaves[i]?.wallet && leaf.amount === d.merkle.leaves[i]?.amount,
    );
  if (!sameLeaves) {
    fail("merkle.leaves", "must list every non-zero creator payout, ordered by wallet");
    return;
  }
  if (n(d.campaignId) === 0n) return; // already reported
  const tree = buildPayoutTree(
    n(d.campaignId),
    leaves.map((leaf) => ({ wallet: leaf.wallet as Hex, amount: n(leaf.amount) })),
  );
  if (d.merkle.root !== tree.root) fail("merkle.root", `expected ${tree.root}`);
}

// ---------------------------------------------------------------------------------------------
// Issues
// ---------------------------------------------------------------------------------------------

function checkIssues(d: ResultDataset, fail: Fail): void {
  const submissions = new Set(d.items.map((item) => item.submissionId));
  const ids = new Set<string>();

  d.issues.forEach((issue, i) => {
    const path = `issues[${i}]`;
    const previous = d.issues[i - 1];
    if (
      previous !== undefined &&
      !lexicographicBefore(
        [n(previous.raisedAt), previous.issueId],
        [n(issue.raisedAt), issue.issueId],
      )
    ) {
      fail(path, "issues must be ordered by raisedAt, then issueId");
    }
    if (ids.has(issue.issueId)) fail(`${path}.issueId`, "duplicate");
    ids.add(issue.issueId);
    if (n(issue.decidedAt) < n(issue.raisedAt)) fail(`${path}.decidedAt`, "before raisedAt");
    if (issue.submissionId !== null && !submissions.has(issue.submissionId)) {
      fail(`${path}.submissionId`, "does not match any item");
    }
  });
}

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/** Parses a decimal field that the schema has already validated. */
function n(value: string): bigint {
  return parseDecimalString(value);
}

function itemBefore(a: DatasetItem, b: DatasetItem): boolean {
  return lexicographicBefore([n(a.receivedAt), a.submissionId], [n(b.receivedAt), b.submissionId]);
}

/** Strict lexicographic order on (number, string) pairs. */
function lexicographicBefore(a: [bigint, string], b: [bigint, string]): boolean {
  if (a[0] !== b[0]) return a[0] < b[0];
  return a[1] < b[1];
}

function strictlySorted(values: readonly string[]): boolean {
  return values.every((value, i) => i === 0 || (values[i - 1] as string) < value);
}

function tryHash(input: unknown): Hex | null {
  try {
    return hashCanonical(input as CanonicalValue);
  } catch {
    return null;
  }
}

function formatPath(path: readonly PropertyKey[]): string {
  return path.reduce<string>((text, key) => {
    if (typeof key === "number") return `${text}[${key}]`;
    return text === "" ? String(key) : `${text}.${String(key)}`;
  }, "");
}
