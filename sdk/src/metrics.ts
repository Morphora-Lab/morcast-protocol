/**
 * Campaign metrics that need exact arithmetic: truncating platform decimals to millionths and
 * the retention adjustment of YouTube Integration campaigns.
 *
 * Platform APIs return decimals such as `0.4567891234`. Parsing them into floating-point numbers
 * could change the result, so every value here is read from its exact decimal text.
 */

import { assertUint256 } from "./uint.js";

/** Retention factors are expressed in millionths: 1,000,000 means 100%. */
export const RETENTION_SCALE = 1_000_000n;

/** One point of a YouTube audience retention report. */
export interface RetentionSample {
  /** elapsedVideoTimeRatio: position in the video from 0 to 1, as exact decimal text. */
  position: string;
  /** audienceWatchRatio at that position, as exact decimal text. May exceed 1. */
  ratio: string;
}

/**
 * Truncates a non-negative decimal to millionths: `floor(value × 1,000,000)`.
 *
 * Accepts JSON number syntax, including exponents.
 *
 * @example
 * trunc6("0.4567891234"). // 456_789n
 * trunc6("2.5E-1").       // 250_000n
 */
export function trunc6(value: string): bigint {
  const { digits, exponent } = parseDecimal(value);
  const shift = exponent + 6; // value × 10^6 = digits × 10^(exponent + 6)
  return shift >= 0 ? digits * 10n ** BigInt(shift) : digits / 10n ** BigInt(-shift);
}

/**
 * Retention factor `R_u` of an Integration segment, in millionths.
 *
 * ```text
 * xs  = segmentStartSec / durationSec,  xe = segmentEndSec / durationSec
 * J   = samples with xs <= position <= xe,
 *       plus the nearest sample strictly before xs and the nearest strictly after xe (if any)
 * R_u = min( min over J of trunc6(ratio), 1,000,000 )
 * ```
 *
 * Positions are compared with `xs` and `xe` exactly, as rational numbers.
 *
 * @returns `R_u`, or `null` when there are no samples (J cannot be formed, so the item is not
 *          measurable).
 * @throws RangeError if the segment does not lie within the video
 *         (`0 <= start < end <= duration`), or a sample is not a non-negative decimal.
 */
export function retentionFactor(
  samples: readonly RetentionSample[],
  segmentStartSec: bigint,
  segmentEndSec: bigint,
  durationSec: bigint,
): bigint | null {
  if (segmentStartSec < 0n || segmentStartSec >= segmentEndSec || segmentEndSec > durationSec) {
    throw new RangeError(
      `segment [${segmentStartSec}, ${segmentEndSec}] must lie within a video of ${durationSec} s`,
    );
  }

  const inside: bigint[] = [];
  let before: { position: Rational; ratio: bigint } | undefined;
  let after: { position: Rational; ratio: bigint } | undefined;

  for (const sample of samples) {
    const position = toRational(sample.position);
    const ratio = trunc6(sample.ratio);

    // Compare position with xs = start / duration and xe = end / duration without division.
    const vsStart = compareRational(position, {
      numerator: segmentStartSec,
      denominator: durationSec,
    });
    const vsEnd = compareRational(position, { numerator: segmentEndSec, denominator: durationSec });

    if (vsStart >= 0 && vsEnd <= 0) {
      inside.push(ratio);
    } else if (vsStart < 0) {
      // Keep the latest sample before xs.
      if (before === undefined || compareRational(position, before.position) > 0) {
        before = { position, ratio };
      }
    } else {
      // Keep the earliest sample after xe.
      if (after === undefined || compareRational(position, after.position) < 0) {
        after = { position, ratio };
      }
    }
  }

  const window = [...inside];
  if (before !== undefined) window.push(before.ratio);
  if (after !== undefined) window.push(after.ratio);
  if (window.length === 0) return null;

  const minimum = window.reduce((min, ratio) => (ratio < min ? ratio : min));
  return minimum < RETENTION_SCALE ? minimum : RETENTION_SCALE;
}

/**
 * The Integration metric: retention-adjusted views, `q = (V × R_u) div 1,000,000`.
 *
 * @param views     V, views during the reporting dates.
 * @param retention R_u in millionths, from {@link retentionFactor}. At most 1,000,000.
 *
 * @example
 * integrationMetric(123_457n, 456_789n). // 56_393n
 */
export function integrationMetric(views: bigint, retention: bigint): bigint {
  assertUint256(views, "views");
  if (retention < 0n || retention > RETENTION_SCALE) {
    throw new RangeError(`retention must be between 0 and ${RETENTION_SCALE}, got ${retention}`);
  }
  return (views * retention) / RETENTION_SCALE;
}

// ---------------------------------------------------------------------------------------------
// Exact decimals
// ---------------------------------------------------------------------------------------------

/** A non-negative rational number. */
interface Rational {
  numerator: bigint;
  denominator: bigint;
}

/** JSON number syntax, without a sign: digits, optional fraction, optional exponent. */
const DECIMAL = /^(0|[1-9]\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/;

/**
 * Parses non-negative decimal text into `digits × 10^exponent` exactly.
 *
 * @example parseDecimal("0.4567") // { digits: 4567n, exponent: -4 }
 */
function parseDecimal(value: string): { digits: bigint; exponent: number } {
  const match = DECIMAL.exec(value);
  if (match === null) throw new RangeError(`not a non-negative decimal: "${value}"`);
  const [, integer = "", fraction = "", exponent = "0"] = match;
  return {
    digits: BigInt(integer + fraction),
    exponent: Number(exponent) - fraction.length,
  };
}

/** Converts decimal text into an exact rational number. */
function toRational(value: string): Rational {
  const { digits, exponent } = parseDecimal(value);
  return exponent >= 0
    ? { numerator: digits * 10n ** BigInt(exponent), denominator: 1n }
    : { numerator: digits, denominator: 10n ** BigInt(-exponent) };
}

/** Three-way comparison of two non-negative rationals by cross-multiplication. */
function compareRational(a: Rational, b: Rational): number {
  const left = a.numerator * b.denominator;
  const right = b.numerator * a.denominator;
  return left < right ? -1 : left > right ? 1 : 0;
}
