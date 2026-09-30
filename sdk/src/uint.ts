/**
 * Integer helpers shared by the SDK.
 *
 * Every amount and metric in the protocol is a non-negative integer that must fit in a Solidity
 * `uint256`, so that off-chain results can be compared with on-chain ones bit for bit.
 */

/** Largest value of a Solidity `uint256`: 2^256 − 1. */
export const MAX_UINT256 = (1n << 256n) - 1n;

/**
 * Throws a `RangeError` unless `value` is an integer in `[0, 2^256)`.
 *
 * @param value The value to check.
 * @param name  The name used in the error message.
 */
export function assertUint256(value: bigint, name: string): void {
  if (value < 0n || value > MAX_UINT256) {
    throw new RangeError(`${name} must be a uint256, got ${value}`);
  }
}
