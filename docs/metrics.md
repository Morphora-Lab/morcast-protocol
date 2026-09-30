# Metrics

Exact rules for metric values that involve decimals. The reference implementation is [`sdk/src/metrics.ts`](../sdk/src/metrics.ts), and the test vectors are in [`vectors/metrics.json`](../vectors/metrics.json).

## Decimal Values

Platform APIs return decimals such as `0.4567891234`. They are read from their exact decimal text, never as floating-point numbers. `trunc6` truncates a value to millionths:

```text
trunc6("0.4567891234") = 456,789
trunc6("2.5E-1")       = 250,000
```

## Integration Metric

For a YouTube Integration item, views count in proportion to the audience that stayed through the declared branded segment.

```text
V   = views during the reporting dates
xs  = segmentStartSec / videoDurationSec
xe  = segmentEndSec / videoDurationSec
J   = retention samples with xs ≤ position ≤ xe,
      plus the nearest sample strictly before xs and the nearest sample strictly after xe (if any)
R_u = min( min over J of trunc6(audienceWatchRatio), 1,000,000 )
q   = (V × R_u) div 1,000,000
```

- Sample positions are compared with `xs` and `xe` exactly, as fractions.
- `audienceWatchRatio` can exceed 1. `R_u` is capped at 1,000,000 (100%).
- Without any retention sample, `J` cannot be formed and the item is not measurable.
- The segment must satisfy `0 ≤ segmentStartSec < segmentEndSec ≤ videoDurationSec`. The duration is the one captured at submission.

Example: `V = 123,457` and the lowest ratio in `J` is `0.4567891234`, so `R_u = 456,789` and `q = 56,393`.
