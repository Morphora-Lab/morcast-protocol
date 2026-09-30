/**
 * Canonical JSON and document hashing.
 *
 * `manifestHash` and `resultHash` are keccak256 hashes of documents serialized as canonical JSON,
 * so that anyone can recompute them from the published document. The serialization follows
 * RFC 8785 (JSON Canonicalization Scheme) restricted to documents without JSON numbers:
 *
 *   - Allowed values: objects, arrays, strings, `true`, `false` and `null`.
 *   - Integers (token amounts, metrics, timestamps, IDs) are decimal strings such as "1000".
 *     JSON numbers are rejected, so no value can lose precision in a JSON parser.
 *   - Object members are sorted by key, comparing keys as UTF-16 code units.
 *   - No whitespace. Strings use the minimal JSON escaping of RFC 8785.
 *   - The hash is keccak256 of the UTF-8 bytes of the serialized text.
 */

import { type Hex, keccak256, stringToBytes } from "viem";

/** A JSON value that can be canonicalized: JSON without numbers. */
export type CanonicalValue =
  | string
  | boolean
  | null
  | readonly CanonicalValue[]
  | { readonly [key: string]: CanonicalValue };

/**
 * Serializes a value as canonical JSON.
 *
 * @throws TypeError if the value contains a number, bigint, `undefined`, a non-plain object or a
 *         string with an unpaired UTF-16 surrogate.
 *
 * @example
 * canonicalize({ b: "2", a: ["x", true, null] }); // '{"a":["x",true,null],"b":"2"}'
 */
export function canonicalize(value: CanonicalValue): string {
  return serialize(value, "$");
}

/**
 * keccak256 of the UTF-8 bytes of the canonical JSON of `value`.
 *
 * @example
 * hashCanonical({}); // keccak256("{}")
 */
export function hashCanonical(value: CanonicalValue): Hex {
  return keccak256(stringToBytes(canonicalize(value)));
}

/**
 * Encodes a non-negative integer as the canonical decimal string used in documents.
 *
 * @example decimalString(1_000n); // "1000"
 */
export function decimalString(value: bigint): string {
  if (value < 0n) throw new RangeError(`expected a non-negative integer, got ${value}`);
  return value.toString(10);
}

/**
 * Parses a canonical decimal string: digits only, no sign, no leading zeros (except "0").
 *
 * @example parseDecimalString("1000"); // 1_000n
 */
export function parseDecimalString(value: string): bigint {
  if (!/^(0|[1-9]\d*)$/.test(value)) throw new RangeError(`not a canonical integer: "${value}"`);
  return BigInt(value);
}

// ---------------------------------------------------------------------------------------------

/** Matches an unpaired high or low surrogate, which has no UTF-8 encoding. */
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

function serialize(value: unknown, path: string): string {
  if (value === null) return "null";
  if (value === true) return "true";
  if (value === false) return "false";
  if (typeof value === "string") return serializeString(value, path);

  if (Array.isArray(value)) {
    return `[${value.map((item, index) => serialize(item, `${path}[${index}]`)).join(",")}]`;
  }

  if (isPlainObject(value)) {
    const members = Object.keys(value)
      .sort(compareUtf16)
      .map((key) => {
        const member = value[key];
        if (member === undefined) throw new TypeError(`${path}.${key} is undefined`);
        return `${serializeString(key, path)}:${serialize(member, `${path}.${key}`)}`;
      });
    return `{${members.join(",")}}`;
  }

  if (typeof value === "number" || typeof value === "bigint") {
    throw new TypeError(`${path} is a number; encode integers as decimal strings`);
  }
  throw new TypeError(`${path} has unsupported type ${typeof value}`);
}

/**
 * RFC 8785 string serialization. ECMAScript `JSON.stringify` escapes exactly the characters the
 * scheme requires (quote, backslash and control characters below U+0020) and writes everything
 * else literally.
 */
function serializeString(value: string, path: string): string {
  if (LONE_SURROGATE.test(value)) throw new TypeError(`${path} contains an unpaired surrogate`);
  return JSON.stringify(value);
}

/**
 * Orders keys by their UTF-16 code units, as RFC 8785 requires. JavaScript's relational string
 * operators compare exactly this way. (Ordering by Unicode code points would differ for keys
 * that mix characters above U+FFFF with characters from U+E000 to U+FFFF.)
 */
function compareUtf16(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}
