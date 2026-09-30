# Settlement Arithmetic

How a campaign budget is divided at settlement. The on-chain implementation is [`SettlementMath`](../src/libraries/SettlementMath.sol).

## Symbols

| Symbol | Name | Meaning |
|---|---|---|
| `B` | budget | Amount the brand escrowed, in token base units. `B > 0` and `B mod 5 == 0`. |
| `T` | target | Campaign goal in the campaign's primary metric. `T > 0`. |
| `S` | recognized | Total recognized delivery reported at settlement, in the same metric. |
| `G` | spent | Part of the budget the brand pays for recognized delivery. |

## Formula

```text
raw    = floor(B × min(S, T) / T)
G      = raw − (raw mod 5)
fee    = G / 5          20% of G, paid to the MORCast treasury
pool   = G − fee        80% of G, claimed by creators
refund = B − G          returned to the brand
```

All arithmetic uses integers, and every division rounds down. The product `B × min(S, T)` is computed with 512-bit precision, so the result is exact for every input.

## Properties

- `fee + pool + refund = B`: no base unit is created or lost.
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

All test vectors are in [`vectors/settlement.json`](../vectors/settlement.json). Integers are decimal strings in token base units, and the tests check every case.
