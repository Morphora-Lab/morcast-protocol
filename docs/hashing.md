# Hashing and Merkle Trees

The rules for recomputing `manifestHash`, `resultHash` and `merkleRoot` from published data. The reference implementations are [`sdk/src/canonical.ts`](../sdk/src/canonical.ts) and [`sdk/src/merkle.ts`](../sdk/src/merkle.ts).

## Document Hashes

The campaign manifest and the result dataset are JSON documents. Each is hashed over a canonical serialization, [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785) (JSON Canonicalization Scheme), restricted to JSON without numbers:

1. Allowed values: objects, arrays, strings, `true`, `false` and `null`. JSON numbers are not allowed.
2. Integers (token amounts, metrics, timestamps in unix seconds, IDs) are decimal strings: digits only, no sign, no leading zeros, and `"0"` for zero.
3. Object members are sorted by key, comparing keys as sequences of UTF-16 code units. Keys are unique.
4. There is no whitespace between tokens.
5. Strings are written literally in UTF-8, except for these escapes:
   - `"` becomes `\"`, and `\` becomes `\\`
   - U+0008, U+0009, U+000A, U+000C and U+000D become `\b`, `\t`, `\n`, `\f` and `\r`
   - every other character below U+0020 becomes `\u00xx`, with lowercase hexadecimal digits.

   Strings must be valid Unicode, with no unpaired surrogates.
6. Arrays keep their order. Each document type defines the order of its arrays.

```text
hash = keccak256(UTF-8 bytes of the canonical text)
```

Example:

```text
value      { "b": "2", "a": ["x", true, null] }
canonical  {"a":["x",true,null],"b":"2"}
```

Rule 3 differs from sorting by Unicode code point only for keys that mix characters above U+FFFF with characters between U+E000 and U+FFFF. The vector `utf16-key-order` covers this case.

## Payout Merkle Tree

Each non-zero creator payout is one leaf:

```text
leaf = keccak256(keccak256(abi.encode(uint256 campaignId, address wallet, uint256 amount)))
```

The tree is an OpenZeppelin `StandardMerkleTree` with default options:

1. Leave out zero payouts. With no leaf at all, the root is 32 zero bytes.
2. Compute every leaf hash and sort the hashes in ascending byte order: `leaf[0] … leaf[n − 1]`.
3. Create an array `node` of `2n − 1` hashes and set `node[2n − 2 − i] = leaf[i]`.
4. For `i` from `n − 2` down to `0`, set `node[i] = hashPair(node[2i + 1], node[2i + 2])`, where `hashPair(a, b) = keccak256(min(a, b) ‖ max(a, b))`.
5. The root is `node[0]`.

The proof of the leaf at index `j` lists the sibling of `j` (`j + 1` if `j` is odd, `j − 1` if even), then the sibling of its parent `(j − 1) / 2`, and so on up to the root. A proof is checked by folding, which is what `MerkleProof.verify` does in the escrow:

```text
h = leaf
for p in proof: h = hashPair(h, p)
valid if h == root
```

## Test Vectors

| File | Content | Checked by |
|---|---|---|
| [`vectors/canonical.json`](../vectors/canonical.json) | Canonical texts and hashes, produced by an independent serializer and hashed with Foundry's `cast keccak` | SDK tests. Solidity `keccak256` |
| [`vectors/merkle.json`](../vectors/merkle.json) | Payout trees with roots, leaves and proofs, produced by the SDK | SDK tests. Solidity tests prove every leaf and claim a full tree through the escrow |
