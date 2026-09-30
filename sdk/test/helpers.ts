import { readFileSync } from "node:fs";

/** Reads a shared vector file from the repository's `vectors/` directory. */
export function loadVectors<T>(name: string): T {
  return JSON.parse(readFileSync(new URL(`../../vectors/${name}`, import.meta.url), "utf8")) as T;
}

/**
 * Deterministic pseudo-random bigints (xorshift64*), so property tests are reproducible.
 */
export class Random {
  private state: bigint;

  constructor(seed: bigint) {
    this.state = seed & 0xffff_ffff_ffff_ffffn || 1n;
  }

  /** A random 64-bit value. */
  next64(): bigint {
    let x = this.state;
    x ^= x >> 12n;
    x ^= (x << 25n) & 0xffff_ffff_ffff_ffffn;
    x ^= x >> 27n;
    this.state = x;
    return (x * 0x2545_f491_4f6c_dd1dn) & 0xffff_ffff_ffff_ffffn;
  }

  /** A random value with up to `bits` bits. */
  bits(bits: number): bigint {
    let value = 0n;
    for (let filled = 0; filled < bits; filled += 64) value = (value << 64n) | this.next64();
    return value & ((1n << BigInt(bits)) - 1n);
  }

  /** A random value in `[min, max]`. */
  between(min: bigint, max: bigint): bigint {
    return min + (this.bits(256) % (max - min + 1n));
  }
}
