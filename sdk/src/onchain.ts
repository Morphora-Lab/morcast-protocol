/**
 * Comparing a result dataset with the campaign recorded by the escrow contract.
 */

import type { Address, Hex, PublicClient } from "viem";

import { morcastEscrowAbi } from "./abi.js";
import { ESCROW_VERSION } from "./constants.js";
import type { ResultDataset } from "./dataset.js";
import type { VerificationError } from "./verify.js";

/** Campaign statuses, indexed by the contract's `Status` enum value. */
export const CAMPAIGN_STATUSES = ["None", "Funded", "Cancelled", "Settled", "Refunded"] as const;

export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];

/** The fields of `MORCastEscrow.getCampaign` that a dataset can be compared with. */
export interface OnChainCampaign {
  status: CampaignStatus;
  brand: Address;
  token: Address;
  budget: bigint;
  target: bigint;
  startAt: bigint;
  endAt: bigint;
  manifestHash: Hex;
  recognized: bigint;
  spent: bigint;
  fee: bigint;
  pool: bigint;
  refund: bigint;
  merkleRoot: Hex;
  resultHash: Hex;
}

/**
 * Reads a campaign from the escrow contract.
 *
 * @example
 * const client = createPublicClient({ transport: http("https://mainnet.base.org") });
 * const campaign = await readCampaign(client, escrowAddress, 1n);
 */
export async function readCampaign(
  client: Pick<PublicClient, "readContract">,
  escrow: Address,
  campaignId: bigint,
): Promise<OnChainCampaign> {
  const c = await client.readContract({
    address: escrow,
    abi: morcastEscrowAbi,
    functionName: "getCampaign",
    args: [campaignId],
  });
  return {
    status: CAMPAIGN_STATUSES[c.status] ?? "None",
    brand: c.brand,
    token: c.token,
    budget: c.budget,
    target: c.target,
    startAt: BigInt(c.startAt),
    endAt: BigInt(c.endAt),
    manifestHash: c.manifestHash,
    recognized: c.recognized,
    spent: c.spent,
    fee: c.fee,
    pool: c.pool,
    refund: c.refund,
    merkleRoot: c.merkleRoot,
    resultHash: c.resultHash,
  };
}

/** Reads the code version of an escrow deployment, for example "1.0.0". */
export async function readEscrowVersion(
  client: Pick<PublicClient, "readContract">,
  escrow: Address,
): Promise<string> {
  return client.readContract({ address: escrow, abi: morcastEscrowAbi, functionName: "VERSION" });
}

/**
 * Whether this SDK can read a deployment of `version`: the major versions must match, because a
 * new major version may change the ABI or the rules.
 */
export function isSupportedEscrowVersion(version: string): boolean {
  return version.split(".")[0] === ESCROW_VERSION.split(".")[0];
}

/**
 * Compares a dataset with the on-chain campaign.
 *
 * The campaign terms (brand, token, budget, target, dates, manifest hash) must always match.
 * Once the campaign is settled, the settlement (recognized total, split, Merkle root and result
 * hash) must match too; a mismatching result hash means this is not the settled revision.
 *
 * @param resultHash The dataset's hash, from `verifyResultDataset`.
 * @returns Every mismatch; empty when the dataset agrees with the chain.
 */
export function compareWithChain(
  dataset: ResultDataset,
  chain: OnChainCampaign,
  resultHash: Hex,
): VerificationError[] {
  if (chain.status === "None") {
    return [{ path: "campaignId", message: "no campaign with this ID exists on-chain" }];
  }

  const errors: VerificationError[] = [];
  const expect = (path: string, actual: string | bigint, onChain: string | bigint) => {
    const same =
      typeof actual === "string" && typeof onChain === "string"
        ? actual.toLowerCase() === onChain.toLowerCase()
        : actual === onChain;
    if (!same) errors.push({ path, message: `on-chain value is ${onChain}` });
  };

  const c = dataset.campaign;
  expect("campaign.brand", c.brand, chain.brand);
  expect("campaign.token", c.token, chain.token);
  expect("campaign.budget", BigInt(c.budget), chain.budget);
  expect("campaign.target", BigInt(c.target), chain.target);
  expect("campaign.startAt", BigInt(c.startAt), chain.startAt);
  expect("campaign.endAt", BigInt(c.endAt), chain.endAt);
  expect("campaign.manifestHash", c.manifestHash, chain.manifestHash);

  if (chain.status === "Settled") {
    const t = dataset.totals;
    expect("totals.recognized", BigInt(t.recognized), chain.recognized);
    expect("totals.spent", BigInt(t.spent), chain.spent);
    expect("totals.fee", BigInt(t.fee), chain.fee);
    expect("totals.pool", BigInt(t.pool), chain.pool);
    expect("totals.refund", BigInt(t.refund), chain.refund);
    expect("merkle.root", dataset.merkle.root, chain.merkleRoot);
    if (resultHash.toLowerCase() !== chain.resultHash.toLowerCase()) {
      errors.push({
        path: "resultHash",
        message: `the campaign was settled with ${chain.resultHash}; this is not the settled revision`,
      });
    }
  }
  return errors;
}
