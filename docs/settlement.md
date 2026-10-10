# Settlement Arithmetic

How creator results become the recognized total `S`, how the budget is divided at settlement, and how the creator pool is divided among creators.

| Rule | Where it runs | Implementation |
|---|---|---|
| Creator scores and `S` | Off-chain | [`sdk/src/settlement.ts`](../sdk/src/settlement.ts) |
| Budget split | On-chain, at `settle` | [`SettlementMath`](../src/libraries/SettlementMath.sol), mirrored in the SDK |
| Creator payouts | Off-chain. Each payout becomes a Merkle leaf | [`sdk/src/payouts.ts`](../sdk/src/payouts.ts) |

## Symbols

| Symbol | Name | Meaning |
|---|---|---|
| `B` | budget | Amount the brand escrowed, in token base units. `B > 0` and `B mod 5 == 0`. |
| `T` | target | Campaign goal in the campaign's primary metric. `T > 0`. |
| `S` | recognized | Total recognized delivery reported at settlement, in the same metric. |
| `G` | spent | Part of the budget the brand pays for recognized delivery. |

## Creator Scores

```text
M   = ceil(T / 100) = (T + 99) div 100
Q_i = sum of creator i's metrics over its passing items
s_i = Q_i if Q_i ≥ M, otherwise 0
S   = Σ s_i
```

`S` is the `recognized` value passed to `settle`.

## Budget Split

```text
raw    = floor(B × min(S, T) / T)
G      = raw − (raw mod 5)
fee    = G / 5          20% of G, paid to the Morcast treasury
pool   = G − fee        80% of G, claimed by creators
refund = B − G          returned to the brand
```

All arithmetic uses integers, and every division rounds down. The product `B × min(S, T)` is computed with 512-bit precision, so the result is exact for every input.

## Properties

- `fee + pool + refund = B`, so no base unit is created or lost.
- `G ≤ B`, `S ≥ T ⇒ G = B`, and `S = 0 ⇒ G = 0`.
- `G` is a multiple of 5, so the 20% / 80% split is exact. Rounding dust, at most 4 base units, stays with the brand.
- More recognized delivery never lowers `G`.

## Examples

| Case | `B` | `T` | `S` | `G` | fee | pool | refund |
|---|---|---|---|---|---|---|---|
| Partial delivery | 100,000 USDC | 1,000,000 | 640,000 | 64,000 | 12,800 | 51,200 | 36,000 |
| Nothing recognized | 100,000 USDC | 1,000,000 | 0 | 0 | 0 | 0 | 100,000 |
| Over-delivery | 100,000 USDC | 1,000,000 | 1,500,000 | 100,000 | 20,000 | 80,000 | 0 |
| Base units | 1,000,000,000 | 3,000 | 1,001 | 333,666,665 | 66,733,333 | 266,933,332 | 666,333,335 |

## Creator Payouts

Over the creators with `s_i > 0`:

```text
base_i   = (pool × s_i) div S
rem_i    = (pool × s_i) mod S
leftover = pool − Σ base_i                 (always fewer than the number of creators)
P_i      = base_i + 1 for the first `leftover` creators ordered by rem_i descending,
           then by wallet address ascending; otherwise P_i = base_i
```

- `Σ P_i = pool`.
- While `S ≤ T`, a creator's payout is about `0.8 × B × s_i / T` and does not depend on other creators. Only when `S > T` do creators share a fixed pool.
- Each non-zero `(campaignId, wallet, P_i)` becomes one Merkle leaf.

Payouts for the partial-delivery example (pool 51,200 USDC, `S = 640,000`):

| Creator | `Q_i` | `s_i` | `P_i` |
|---|---|---|---|
| c1 | 300,000 | 300,000 | 24,000 USDC |
| c2 | 180,000 | 180,000 | 14,400 USDC |
| c3 | 120,000 | 120,000 | 9,600 USDC |
| c4 | 40,000 | 40,000 | 3,200 USDC |
| c5 | 9,000 | 0 (below `M = 10,000`) | 0 |

## Test Vectors

- [`vectors/settlement.json`](../vectors/settlement.json): budget splits.
- [`vectors/payouts.json`](../vectors/payouts.json): creator payouts, including the tie-break examples.

Integers are decimal strings in token base units. The Solidity tests and the SDK tests both check every case.
