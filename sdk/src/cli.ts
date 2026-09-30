/**
 * `morcast-verify`: verifies a published result dataset from the command line.
 *
 *   morcast-verify <dataset.json> [--rpc-url <url>] [--json]
 *
 * Without `--rpc-url`, the dataset is checked on its own. With it, the campaign is also read from
 * the escrow contract named in the dataset and compared. Exit codes: 0 when everything matches,
 * 1 when a check fails, 2 on a usage or input error.
 */

import { readFileSync } from "node:fs";

import { createPublicClient, type Hex, http } from "viem";

import { compareWithChain, type OnChainCampaign, readCampaign } from "./onchain.js";
import { type VerificationError, type VerificationReport, verifyResultDataset } from "./verify.js";

const USAGE = "usage: morcast-verify <dataset.json> [--rpc-url <url>] [--json]";

/** Output streams and chain access, replaceable in tests. */
export interface CliEnvironment {
  out: (line: string) => void;
  err: (line: string) => void;
  readFile: (path: string) => string;
  /** Returns the chain ID and a reader for campaigns on the chain at `rpcUrl`. */
  connect: (rpcUrl: string) => {
    chainId: () => Promise<number>;
    readCampaign: (escrow: Hex, campaignId: bigint) => Promise<OnChainCampaign>;
  };
}

const defaultEnvironment: CliEnvironment = {
  out: (line) => process.stdout.write(`${line}\n`),
  err: (line) => process.stderr.write(`${line}\n`),
  readFile: (path) => readFileSync(path, "utf8"),
  connect: (rpcUrl) => {
    const client = createPublicClient({ transport: http(rpcUrl) });
    return {
      chainId: () => client.getChainId(),
      readCampaign: (escrow, campaignId) => readCampaign(client, escrow, campaignId),
    };
  },
};

/**
 * Runs the command with the given arguments (without `node` and the script path).
 *
 * @returns The process exit code.
 */
export async function main(
  args: readonly string[],
  env: CliEnvironment = defaultEnvironment,
): Promise<number> {
  const options = parseArgs(args);
  if (typeof options === "string") {
    env.err(options);
    env.err(USAGE);
    return 2;
  }

  let input: unknown;
  try {
    input = JSON.parse(env.readFile(options.file));
  } catch (error) {
    env.err(`cannot read ${options.file}: ${(error as Error).message}`);
    return 2;
  }

  const report = verifyResultDataset(input);
  let chainErrors: VerificationError[] = [];
  let chainStatus: string | null = null;

  if (options.rpcUrl !== null && report.dataset !== null && report.resultHash !== null) {
    try {
      const chain = env.connect(options.rpcUrl);
      const chainId = await chain.chainId();
      if (BigInt(chainId) !== BigInt(report.dataset.chainId)) {
        chainErrors = [{ path: "chainId", message: `the RPC endpoint serves chain ${chainId}` }];
      } else {
        const campaign = await chain.readCampaign(
          report.dataset.escrow as Hex,
          BigInt(report.dataset.campaignId),
        );
        chainStatus = campaign.status;
        chainErrors = compareWithChain(report.dataset, campaign, report.resultHash);
      }
    } catch (error) {
      env.err(`cannot read the campaign on-chain: ${(error as Error).message}`);
      return 2;
    }
  }

  const passed = report.valid && chainErrors.length === 0;
  if (options.json) {
    env.out(
      JSON.stringify(
        {
          valid: passed,
          resultHash: report.resultHash,
          errors: report.errors,
          onChain: options.rpcUrl === null ? null : { status: chainStatus, errors: chainErrors },
        },
        null,
        2,
      ),
    );
  } else {
    printReport(report, options.rpcUrl === null ? null : { chainStatus, chainErrors }, env);
  }
  return passed ? 0 : 1;
}

function printReport(
  report: VerificationReport,
  chain: { chainStatus: string | null; chainErrors: VerificationError[] } | null,
  env: CliEnvironment,
): void {
  const d = report.dataset;
  if (d !== null) {
    env.out(`Campaign     ${d.campaignId} on chain ${d.chainId}, escrow ${d.escrow}`);
    env.out(`Revision     ${d.revision}`);
  }
  env.out(`resultHash   ${report.resultHash ?? "(not a canonical document)"}`);
  if (d !== null) {
    const t = d.totals;
    env.out(`merkleRoot   ${d.merkle.root}`);
    env.out(`Recognized   ${t.recognized} of target ${d.campaign.target}`);
    env.out(`Split        spent ${t.spent}, fee ${t.fee}, pool ${t.pool}, refund ${t.refund}`);
  }

  if (report.valid && d !== null) {
    const leaves = d.merkle.leaves.length;
    env.out(
      `Dataset      valid: ${d.items.length} items, ${d.creators.length} creators, ${leaves} payouts`,
    );
  } else {
    env.out(`Dataset      ${report.errors.length} error(s)`);
    for (const error of report.errors) env.out(`  ${error.path}: ${error.message}`);
  }

  if (chain !== null) {
    if (chain.chainErrors.length === 0) {
      const status = chain.chainStatus ?? "unknown";
      env.out(`On-chain     ${status}; the dataset matches the campaign`);
    } else {
      env.out(`On-chain     ${chain.chainErrors.length} mismatch(es)`);
      for (const error of chain.chainErrors) env.out(`  ${error.path}: ${error.message}`);
    }
  }
}

interface Options {
  file: string;
  rpcUrl: string | null;
  json: boolean;
}

/** Parses the arguments, or returns an error message. */
function parseArgs(args: readonly string[]): Options | string {
  let file: string | null = null;
  let rpcUrl: string | null = null;
  let json = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i] as string;
    if (arg === "--json") {
      json = true;
    } else if (arg === "--rpc-url") {
      const value = args[++i];
      if (value === undefined) return "--rpc-url needs a value";
      rpcUrl = value;
    } else if (arg.startsWith("--")) {
      return `unknown option ${arg}`;
    } else if (file === null) {
      file = arg;
    } else {
      return `unexpected argument ${arg}`;
    }
  }
  return file === null ? "missing dataset file" : { file, rpcUrl, json };
}
