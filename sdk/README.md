# @morcast/protocol

TypeScript implementation of the Morcast Payment Protocol arithmetic. It computes exactly what the escrow contract computes, plus the off-chain rules that produce the contract's inputs: creator scores, creator payouts and Integration metrics.

## Status

Complete for protocol v2: settlement, payouts, metrics, document hashing, payout Merkle trees and result dataset verification, tested against the shared vectors in [`../vectors`](../vectors). Version `2.0.0`, released with protocol `v2.0.0`. It reads version 2 escrows only, whose fee is 8%. To check a campaign of a version 1 escrow (20% fee), use the `v1.0.0` package. The package is attached to each GitHub release. It is not on npm.

## Install

Each [release](https://github.com/Morphora-Lab/morcast-protocol/releases) carries the package. Install it from there:

```sh
pnpm add https://github.com/Morphora-Lab/morcast-protocol/releases/download/v2.0.0/morcast-protocol-2.0.0.tgz
```

The lockfile records the package's hash, so every later install gets exactly the same files. To confirm that the release workflow built a downloaded package from this repository:

```sh
gh attestation verify morcast-protocol-2.0.0.tgz --repo Morphora-Lab/morcast-protocol
```

The package is ESM only and needs Node.js 20 or later.

## Usage

```ts
import {
  allocatePayouts,
  creatorScore,
  creatorThreshold,
  recognizedTotal,
  split,
} from "@morcast/protocol";

const budget = 100_000_000_000n; // 100,000 USDC (6 decimals)
const target = 1_000_000n;
const threshold = creatorThreshold(target); // 10_000n

const creators = [
  { wallet: "0x00000000000000000000000000000000000000c1", total: 300_000n },
  { wallet: "0x00000000000000000000000000000000000000c2", total: 180_000n },
  { wallet: "0x00000000000000000000000000000000000000c3", total: 9_000n }, // below the threshold
] as const;

const scores = creators.map((c) => ({ wallet: c.wallet, score: creatorScore(c.total, threshold) }));
const recognized = recognizedTotal(scores.map((s) => s.score)); // 480_000n

const { fee, pool, refund } = split(budget, target, recognized);
// fee 3_840_000_000n, pool 44_160_000_000n, refund 52_000_000_000n

const payouts = allocatePayouts(pool, scores);
// payouts 27_600_000_000n, 16_560_000_000n, 0n
```

Build the payout tree for `settle` and `claim`, and hash a document:

```ts
import { buildPayoutTree, hashCanonical } from "@morcast/protocol";

const tree = buildPayoutTree(1n, payouts.map((p) => ({ wallet: p.wallet, amount: p.payout })));
tree.root;               // merkleRoot for settle()
tree.leaves[0].proof;    // proof for claim()

hashCanonical({ campaignId: "1", status: "PASS" }); // keccak256 of the canonical JSON
```

Verify a published result dataset, on its own or against the escrow:

```ts
import { compareWithChain, readCampaign, verifyResultDataset } from "@morcast/protocol";

const report = verifyResultDataset(JSON.parse(readFileSync("result.json", "utf8")));
report.valid;       // every check passed
report.errors;      // [{ path: "totals.fee", message: "expected 5120000000" }, ...]
report.resultHash;  // the hash that settle() must use

const onChain = await readCampaign(publicClient, escrowAddress, 1n);
compareWithChain(report.dataset, onChain, report.resultHash); // [] when everything matches
```

The same checks are available as a command:

```sh
morcast-verify result.json [--rpc-url <url>] [--json]
```

## API

All values are `bigint`. Every function throws a `RangeError` on invalid input.

| Function | Result |
|---|---|
| `split(budget, target, recognized)` | `{ spent, fee, pool, refund }`, identical to the contract's `SettlementMath.split` |
| `FEE_NUMERATOR`, `FEE_DENOMINATOR` | The fee is `2 / 25` (8%) of what a campaign spends. A budget must be a multiple of `FEE_DENOMINATOR` |
| `creatorThreshold(target)` | `M = ceil(T / 100)` |
| `creatorScore(total, threshold)` | `total` if `total ≥ threshold`, otherwise `0` |
| `recognizedTotal(scores)` | `S`, the sum of the scores |
| `allocatePayouts(pool, creators)` | Each creator with its `payout`. The payouts add up to `pool`. |
| `trunc6(decimal)` | Decimal text truncated to millionths |
| `retentionFactor(samples, startSec, endSec, durationSec)` | Integration retention `R_u` in millionths, or `null` when not measurable |
| `integrationMetric(views, retention)` | `q = views × R_u div 1,000,000` |
| `canonicalize(value)` | RFC 8785 canonical JSON of a number-free document |
| `hashCanonical(value)` | keccak256 of the canonical JSON (`manifestHash`, `resultHash`) |
| `buildPayoutTree(campaignId, payouts)` | `{ root, leaves }`, each leaf with its hash and proof. Zero payouts are left out. |
| `payoutLeafHash(campaignId, wallet, amount)` | The leaf hash, identical to `MorcastEscrow.leafHash` |
| `verifyPayoutProof(root, campaignId, wallet, amount, proof)` | Whether `claim` would accept the proof |
| `verifyResultDataset(input)` | `{ valid, errors, resultHash, dataset }` for a published result dataset |
| `resultDatasetSchema` | The dataset schema (zod), `morcast.result.v1` |
| `readCampaign(client, escrow, campaignId)` | The campaign as stored by the escrow |
| `compareWithChain(dataset, campaign, resultHash)` | Mismatches between a dataset and the on-chain campaign |
| `morcastEscrowAbi` | ABI of `MorcastEscrow`, generated from the compiled contract |
| `ESCROW_CODE_HASH`, `isGenuineEscrow(client, escrow)` | keccak256 of the escrow's runtime code, identical for every deployment of this version, and whether a deployment runs that code |
| `SETTLEMENT_OPENS_AFTER`, `SETTLEMENT_CLOSES_AFTER`, `MAX_CAMPAIGN_DURATION` | The contract's timing constants in seconds: Day 5, Day 10 and 90 days |
| `ESCROW_VERSION`, `readEscrowVersion(client, escrow)`, `isSupportedEscrowVersion(version)` | The escrow version this SDK implements, a deployment's version, and whether the SDK can read it (same major version) |

The rules are specified in [`docs/settlement.md`](../docs/settlement.md), [`docs/metrics.md`](../docs/metrics.md), [`docs/hashing.md`](../docs/hashing.md) and [`docs/dataset.md`](../docs/dataset.md).

## Development

Requirements: Node.js 20 or later and pnpm 10.

```sh
pnpm install
pnpm test        # every case in ../vectors plus property tests
pnpm lint        # Biome
pnpm typecheck
pnpm build       # emits dist/, including the morcast-verify command (dist/bin.js)
```

`src/abi.ts` (ABI and code hash) is generated from the compiled contract by running `forge build && node sdk/scripts/generate-abi.mjs` from the repository root. CI fails if it is out of date.

`test/fixtures/example.ts` builds [`examples/result-dataset.json`](../examples/result-dataset.json). A test fails if they differ. After changing the fixture, run `UPDATE_EXAMPLES=1 pnpm test` to rewrite the file.
