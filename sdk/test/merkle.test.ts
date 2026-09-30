import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import type { Address, Hex } from "viem";
import { describe, expect, it } from "vitest";

import {
  buildPayoutTree,
  EMPTY_ROOT,
  hashPair,
  type Payout,
  payoutLeafHash,
  verifyPayoutProof,
} from "../src/index.js";
import { loadVectors, Random } from "./helpers.js";

interface MerkleVectors {
  cases: {
    name: string;
    campaignId: string;
    root: Hex;
    leaves: { wallet: Address; amount: string; leaf: Hex; proof: Hex[] }[];
  }[];
}

function wallet(n: bigint): Address {
  return `0x${n.toString(16).padStart(40, "0")}`;
}

/**
 * The tree construction as documented in docs/hashing.md, written independently of the library:
 * sort the leaf hashes, place them at the end of an array of 2n − 1 nodes in reverse order, then
 * fill each inner node i with hashPair(node[2i + 1], node[2i + 2]).
 */
function documentedRoot(campaignId: bigint, payouts: Payout[]): Hex {
  const leaves = payouts
    .filter((p) => p.amount > 0n)
    .map((p) => payoutLeafHash(campaignId, p.wallet, p.amount))
    .sort();
  if (leaves.length === 0) return EMPTY_ROOT;
  const nodes: Hex[] = new Array(2 * leaves.length - 1);
  leaves.forEach((leaf, i) => {
    nodes[nodes.length - 1 - i] = leaf;
  });
  for (let i = nodes.length - 1 - leaves.length; i >= 0; i--) {
    nodes[i] = hashPair(nodes[2 * i + 1] as Hex, nodes[2 * i + 2] as Hex);
  }
  return nodes[0] as Hex;
}

function randomPayouts(random: Random, count: number): Payout[] {
  return Array.from({ length: count }, (_, i) => ({
    wallet: wallet((random.bits(152) << 8n) | BigInt(i)), // unique low byte
    amount: random.between(1n, 1n << 96n),
  }));
}

describe("payoutLeafHash", () => {
  it("matches the StandardMerkleTree leaf hash", () => {
    const random = new Random(1n);
    for (let i = 0; i < 200; i++) {
      const id = random.between(1n, 1n << 64n);
      const [{ wallet: w, amount } = { wallet: wallet(1n), amount: 1n }] = randomPayouts(random, 1);
      const tree = StandardMerkleTree.of([[id, w, amount]], ["uint256", "address", "uint256"]);
      expect(payoutLeafHash(id, w, amount)).toBe(tree.leafHash([id, w, amount]));
    }
  });
});

describe("buildPayoutTree", () => {
  const { cases } = loadVectors<MerkleVectors>("merkle.json");

  it.each(cases)("reproduces vector $name", (c) => {
    const tree = buildPayoutTree(
      BigInt(c.campaignId),
      c.leaves.map((l) => ({ wallet: l.wallet, amount: BigInt(l.amount) })),
    );
    expect(tree.root).toBe(c.root);
    expect(tree.leaves.map((l) => ({ ...l, amount: l.amount.toString() }))).toEqual(c.leaves);
  });

  it("matches the documented construction and produces valid proofs", () => {
    const random = new Random(99n);
    for (let size = 1; size <= 17; size++) {
      const id = random.between(1n, 1_000n);
      const payouts = randomPayouts(random, size);
      const tree = buildPayoutTree(id, payouts);

      expect(tree.root).toBe(documentedRoot(id, payouts));
      for (const leaf of tree.leaves) {
        expect(verifyPayoutProof(tree.root, id, leaf.wallet, leaf.amount, leaf.proof)).toBe(true);
        // Any change to the claimed value invalidates the proof.
        expect(verifyPayoutProof(tree.root, id, leaf.wallet, leaf.amount + 1n, leaf.proof)).toBe(
          false,
        );
        expect(verifyPayoutProof(tree.root, id + 1n, leaf.wallet, leaf.amount, leaf.proof)).toBe(
          false,
        );
      }
    }
  });

  it("orders leaves by wallet and leaves out zero payouts", () => {
    const tree = buildPayoutTree(1n, [
      { wallet: wallet(3n), amount: 30n },
      { wallet: wallet(1n), amount: 0n },
      { wallet: wallet(2n), amount: 20n },
    ]);
    expect(tree.leaves.map((l) => l.wallet)).toEqual([wallet(2n), wallet(3n)]);
  });

  it("uses the empty root when there is nothing to claim", () => {
    expect(buildPayoutTree(1n, []).root).toBe(EMPTY_ROOT);
    expect(buildPayoutTree(1n, [{ wallet: wallet(1n), amount: 0n }])).toEqual({
      campaignId: 1n,
      root: EMPTY_ROOT,
      leaves: [],
    });
  });

  it("uses the leaf itself as the root of a single-leaf tree", () => {
    const tree = buildPayoutTree(5n, [{ wallet: wallet(1n), amount: 7n }]);
    expect(tree.root).toBe(payoutLeafHash(5n, wallet(1n), 7n));
    expect(tree.leaves[0]?.proof).toEqual([]);
  });

  it("rejects invalid input", () => {
    expect(() => buildPayoutTree(0n, [])).toThrow(RangeError);
    expect(() =>
      buildPayoutTree(1n, [
        { wallet: wallet(1n), amount: 1n },
        { wallet: wallet(1n), amount: 2n },
      ]),
    ).toThrow(/duplicate/);
    expect(() => buildPayoutTree(1n, [{ wallet: wallet(1n), amount: -1n }])).toThrow(RangeError);
    expect(() => buildPayoutTree(1n, [{ wallet: wallet(0n), amount: 1n }])).toThrow(/zero address/);
  });
});
