# @morcast/protocol

TypeScript implementation of the MORCast Payment Protocol arithmetic. It computes exactly what the escrow contract computes, plus the off-chain rules that produce the contract's inputs: creator scores, creator payouts and Integration metrics.

## Status

Settlement, payouts, metrics, document hashing and payout Merkle trees are implemented and tested against the shared vectors in [`../vectors`](../vectors). The result verifier is planned. The package is not yet published to npm.

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
// fee 9_600_000_000n, pool 38_400_000_000n, refund 52_000_000_000n

const payouts = allocatePayouts(pool, scores);
// payouts 24_000_000_000n, 14_400_000_000n, 0n
```

Build the payout tree for `settle` and `claim`, and hash a document:

```ts
import { buildPayoutTree, hashCanonical } from "@morcast/protocol";

const tree = buildPayoutTree(1n, payouts.map((p) => ({ wallet: p.wallet, amount: p.payout })));
tree.root;               // merkleRoot for settle()
tree.leaves[0].proof;    // proof for claim()

hashCanonical({ campaignId: "1", status: "PASS" }); // keccak256 of the canonical JSON
```

## API

All values are `bigint`. Every function throws a `RangeError` on invalid input.

| Function | Result |
|---|---|
| `split(budget, target, recognized)` | `{ spent, fee, pool, refund }`, identical to the contract's `SettlementMath.split` |
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
| `payoutLeafHash(campaignId, wallet, amount)` | The leaf hash, identical to `MORCastEscrow.leafHash` |
| `verifyPayoutProof(root, campaignId, wallet, amount, proof)` | Whether `claim` would accept the proof |

The rules are specified in [`docs/settlement.md`](../docs/settlement.md), [`docs/metrics.md`](../docs/metrics.md) and [`docs/hashing.md`](../docs/hashing.md).

## Development

Requirements: Node.js 20 or later and pnpm 10.

```sh
pnpm install
pnpm test        # every case in ../vectors plus property tests
pnpm lint        # Biome
pnpm typecheck
pnpm build       # emits dist/
```
