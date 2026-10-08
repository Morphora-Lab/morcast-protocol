/**
 * The result dataset: the document MORCast publishes for each campaign after measurement.
 *
 * It lists every accepted submission with its status and metric, every creator's total, score
 * and payout, the settlement totals and the Merkle leaves. `resultHash`, passed to `settle`, is
 * the canonical hash of this document. The format is specified in docs/dataset.md.
 *
 * All integers are decimal strings, addresses and hashes are lowercase hex, and every array has a
 * defined order, so the same result always produces the same hash.
 */

import { z } from "zod";

/** Identifier of this schema version, stored in the `schema` field. */
export const RESULT_SCHEMA = "morcast.result.v1";

/** A non-negative integer as a canonical decimal string. */
const uint = z.string().regex(/^(0|[1-9]\d*)$/, "expected a canonical decimal integer");

/** A lowercase 20-byte address. */
const address = z.string().regex(/^0x[0-9a-f]{40}$/, "expected a lowercase address");

/** A lowercase 32-byte hash. */
const bytes32 = z.string().regex(/^0x[0-9a-f]{64}$/, "expected a lowercase 32-byte hash");

/** A reason code such as NOT_PUBLIC. */
const reasonCode = z.string().regex(/^[A-Z][A-Z0-9_]*$/, "expected an upper-case reason code");

/** A non-empty text field. */
const text = z.string().min(1);

/** Campaign terms, as recorded on-chain and in the manifest. */
export const campaignSchema = z.strictObject({
  /** keccak256 of the canonical manifest. */
  manifestHash: bytes32,
  /** The brand wallet that created the campaign. */
  brand: address,
  /** The campaign token (USDC or MOR). */
  token: address,
  platform: z.enum(["X", "YOUTUBE"]),
  /** YouTube format. Null for X campaigns. */
  format: z.enum(["DEDICATED", "INTEGRATION"]).nullable(),
  /** B, in token base units. */
  budget: uint,
  /** T, in the primary metric. */
  target: uint,
  /** M = ceil(T / 100). */
  threshold: uint,
  /** Campaign window [startAt, endAt), unix seconds. */
  startAt: uint,
  endAt: uint,
});

/** Retention evidence of a YouTube Integration item. */
export const integrationSchema = z.strictObject({
  /** V: views during the reporting dates. */
  views: uint,
  /** Declared branded segment, whole seconds. */
  segmentStartSec: uint,
  segmentEndSec: uint,
  /** Video duration captured at submission, seconds. */
  durationSec: uint,
  /** R_u in millionths (at most 1,000,000). */
  retention: uint,
});

/** One accepted submission. */
export const itemSchema = z.strictObject({
  submissionId: text,
  wallet: address,
  /** Platform account ID of the content's author (X user ID or YouTube channel ID). */
  account: text,
  /** Platform content ID (X post ID or YouTube video ID). */
  contentId: text,
  contentUrl: text,
  /** When MORCast received the submission, unix seconds. */
  receivedAt: uint,
  status: z.enum(["PASS", "FAIL"]),
  /** All applicable reason codes, sorted and unique. Empty for PASS. */
  reasons: z.array(reasonCode),
  /** The reason that decided a FAIL. Null for PASS. */
  primaryReason: reasonCode.nullable(),
  /** q in the primary metric. "0" for FAIL. */
  metric: uint,
  /** When the metric was retrieved, unix seconds. Null if never measured. */
  retrievedAt: uint.nullable(),
  /** Reference to the evidence bundle. Null if none was captured. */
  evidence: text.nullable(),
  /** Retention evidence for Integration items. Null otherwise. */
  integration: integrationSchema.nullable(),
});

/** Totals and payout of one creator (one wallet). */
export const creatorSchema = z.strictObject({
  wallet: address,
  /**
   * The platform accounts of the wallet's items in this campaign, sorted and unique. A creator
   * may take part with several accounts. Each account belongs to one wallet.
   */
  accounts: z.array(text),
  /** Q: sum of the metrics of the wallet's PASS items. */
  total: uint,
  /** s: Q if Q >= M, otherwise 0. */
  score: uint,
  /** P: the wallet's share of the creator pool. */
  payout: uint,
});

/** An issue raised during review, with MORCast's decision. */
export const issueSchema = z.strictObject({
  issueId: text,
  /** Wallet of the creator or brand that raised the issue. */
  raisedBy: address,
  raisedAt: uint,
  /** The submission the issue concerns. Null for campaign-wide issues. */
  submissionId: text.nullable(),
  summary: text,
  outcome: z.enum(["UPHELD", "REJECTED"]),
  decision: text,
  decidedAt: uint,
});

/** The complete result dataset. */
export const resultDatasetSchema = z.strictObject({
  schema: z.literal(RESULT_SCHEMA),
  chainId: uint,
  /** Address of the escrow contract that holds the campaign. */
  escrow: address,
  campaignId: uint,
  /** "0" for the first publication. Increases by one with every revision. */
  revision: uint,
  /** resultHash of the previous revision. Null for revision "0". */
  previousResultHash: bytes32.nullable(),
  /** Publication time, unix seconds. */
  publishedAt: uint,
  campaign: campaignSchema,
  /** Ordered by receivedAt, then submissionId. */
  items: z.array(itemSchema),
  /** One entry per wallet that has an item, ordered by wallet address. */
  creators: z.array(creatorSchema),
  totals: z.strictObject({
    /** S = Σ score. */
    recognized: uint,
    /** G, fee, pool and refund from the settlement formula. */
    spent: uint,
    fee: uint,
    pool: uint,
    refund: uint,
  }),
  merkle: z.strictObject({
    /** Root passed to `settle`. All zeros when there are no leaves. */
    root: bytes32,
    /** Creators with a non-zero payout, ordered by wallet address. */
    leaves: z.array(z.strictObject({ wallet: address, amount: uint })),
  }),
  /** Ordered by raisedAt, then issueId. */
  issues: z.array(issueSchema),
});

export type ResultDataset = z.infer<typeof resultDatasetSchema>;
export type DatasetCampaign = z.infer<typeof campaignSchema>;
export type DatasetItem = z.infer<typeof itemSchema>;
export type DatasetCreator = z.infer<typeof creatorSchema>;
export type DatasetIssue = z.infer<typeof issueSchema>;
