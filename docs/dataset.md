# Result Dataset

The document MORCast publishes for every campaign after measurement. It lists each accepted submission with its status and metric, each creator's total, score and payout, the settlement totals and the Merkle leaves. `resultHash`, passed to `settle`, is the [canonical hash](hashing.md) of this document, so anyone can check that a settlement matches what was published.

Schema version: `morcast.result.v1`. The schema is implemented in [`sdk/src/dataset.ts`](../sdk/src/dataset.ts), and a complete example is [`examples/result-dataset.json`](../examples/result-dataset.json).

## Conventions

- Integers (amounts, metrics, timestamps, IDs) are decimal strings. Timestamps are unix seconds.
- Addresses and hashes are lowercase hexadecimal with a `0x` prefix.
- Unknown fields are not allowed.
- Every array has a fixed order (below), so the same result always produces the same hash.

## Fields

| Field | Meaning |
|---|---|
| `schema` | `"morcast.result.v1"` |
| `chainId`, `escrow`, `campaignId` | The chain, the escrow contract and the campaign this dataset settles |
| `revision` | `"0"` for the first publication, increased by one for each revision |
| `previousResultHash` | `resultHash` of the previous revision; `null` for revision `"0"` |
| `publishedAt` | Publication time |
| `campaign` | Terms: `manifestHash`, `brand`, `token`, `platform` (`X` or `YOUTUBE`), `format` (`DEDICATED` or `INTEGRATION`; `null` for X), `budget`, `target`, `threshold` (`M`), `startAt`, `endAt` |
| `items` | Accepted submissions, ordered by `receivedAt`, then `submissionId` |
| `creators` | One entry per wallet that has an item, ordered by wallet address |
| `totals` | `recognized` (`S`), `spent` (`G`), `fee`, `pool` and `refund` |
| `merkle` | `root`, and `leaves`: every creator with a non-zero payout (`wallet`, `amount`), ordered by wallet address |
| `issues` | Issues raised during review with their decisions, ordered by `raisedAt`, then `issueId` |

### Item

| Field | Meaning |
|---|---|
| `submissionId` | Unique ID of the submission |
| `wallet` | Submitting wallet |
| `account` | Platform account of the content's author: X user ID or YouTube channel ID |
| `contentId`, `contentUrl` | X post ID or YouTube video ID, and its URL |
| `receivedAt` | When MORCast received the submission (before `endAt`) |
| `status` | `PASS` or `FAIL` |
| `reasons` | All applicable reason codes, sorted and unique. Empty for `PASS`. |
| `primaryReason` | The reason that decided a `FAIL`; `null` for `PASS` |
| `metric` | `q` in the primary metric; `"0"` for `FAIL` |
| `retrievedAt` | When the metric was retrieved; `null` if it never was |
| `evidence` | Reference to the evidence bundle; `null` if nothing was captured |
| `integration` | Integration campaigns only: `views` (`V`), `segmentStartSec`, `segmentEndSec`, `durationSec` and `retention` (`R_u` in millionths). Otherwise `null`. |

### Creator

| Field | Meaning |
|---|---|
| `wallet` | The creator's wallet |
| `account` | The platform account paired with the wallet in this campaign |
| `total` | `Q`: sum of the metrics of the wallet's `PASS` items |
| `score` | `s`: `Q` if `Q ≥ M`, otherwise `0` |
| `payout` | `P`: the wallet's share of the creator pool |

### Issue

| Field | Meaning |
|---|---|
| `issueId` | Unique ID of the issue |
| `raisedBy` | Wallet of the creator or brand that raised it |
| `raisedAt`, `decidedAt` | When it was raised and decided |
| `submissionId` | The submission it concerns; `null` for campaign-wide issues |
| `summary`, `decision` | What was raised and what MORCast decided |
| `outcome` | `UPHELD` or `REJECTED` |

Issues are raised after the first publication, so revision `"0"` has none.

## Reason Codes

Codes defined by the specification:

| Code | Meaning |
|---|---|
| `NOT_OWNER` | The content's author account is not linked to the submitting wallet. |
| `ACCOUNT_MISMATCH` | The wallet already uses another account in this campaign, or the account is used by another wallet. |
| `OVER_LIMIT` | The wallet exceeded the campaign's submission limit. |
| `DUPLICATE` | The same content or performance is already counted. |
| `OUT_OF_WINDOW` | The content was not posted within `[startAt, endAt)`. |
| `EDITED` | Campaign-relevant content changed after capture in a way the manifest does not allow. |
| `NOT_PUBLIC` | The content was not public at the `endAt` or Day-3 check. |
| `NOT_MEASURABLE` | The metric could not be retrieved or computed. |
| `FRAUD` | Fraud under the manifest's standard. |
| `WITHDRAWN` | The creator withdrew the submission. |

Codes for compliance checks (required elements, semantic and visual requirements) are defined by the verifier version pinned in the manifest. Every code is upper case, with digits and underscores allowed.

## Verification

`verifyResultDataset` in the SDK, and the `morcast-verify` command, check that:

- the document matches the schema;
- `threshold = ceil(target / 100)`, the budget is positive and a multiple of 5, `startAt < endAt` with at most 90 days between them, and the dataset was published after `endAt`;
- revision `"0"` has no previous hash and no issues, and later revisions have a previous hash;
- items are in order, submission IDs are unique, and every submission was received before `endAt`;
- `PASS` items have no reasons; `FAIL` items have sorted reasons, a primary reason among them, and a metric of `0`;
- no content ID is counted twice, and wallets and accounts are paired one to one;
- Integration `PASS` items have valid segments and `metric = views × retention div 1,000,000`;
- creator totals, scores, `S`, the settlement split and every payout follow [the settlement rules](settlement.md);
- the Merkle leaves are exactly the non-zero payouts, and the root matches [the tree construction](hashing.md).

Metrics and statuses are MORCast's measurements and are taken as published. Everything derived from them is recomputed.

With an RPC endpoint, the campaign terms are also compared with the escrow. Once the campaign is settled, `S`, the split, the Merkle root and `resultHash` must match too.

```sh
morcast-verify examples/result-dataset.json
morcast-verify result.json --rpc-url https://mainnet.base.org
morcast-verify result.json --json
```

Exit codes: `0` when every check passes, `1` when a check fails, `2` on a usage or input error.
