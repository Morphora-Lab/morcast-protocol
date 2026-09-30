/**
 * Creator payout Merkle trees.
 *
 * Each creator payout is a leaf over the value `(campaignId, wallet, amount)`. The tree is an
 * OpenZeppelin `StandardMerkleTree` with the leaf encoding `(uint256, address, uint256)`, which
 * is exactly what `MORCastEscrow.claim` verifies:
 *
 *   leaf = keccak256(keccak256(abi.encode(campaignId, wallet, amount)))
 *   node = keccak256(sort(left, right))       the smaller hash comes first
 */

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import {
  type Address,
  concat,
  encodeAbiParameters,
  type Hex,
  isAddress,
  keccak256,
  parseAbiParameters,
} from "viem";

import { assertUint256 } from "./uint.js";

/** ABI types of a payout leaf value, in order: campaign ID, wallet, amount. */
export const PAYOUT_LEAF_ENCODING = ["uint256", "address", "uint256"] as const;

/** Merkle root of a campaign without payouts (nothing recognized or an empty pool). */
export const EMPTY_ROOT: Hex = `0x${"00".repeat(32)}`;

const LEAF_PARAMETERS = parseAbiParameters("uint256, address, uint256");

/** A creator payout to put in the tree. */
export interface Payout {
  wallet: Address;
  amount: bigint;
}

/** A leaf of the payout tree with everything needed to claim it. */
export interface PayoutLeaf extends Payout {
  /** The leaf hash, as `MORCastEscrow.leafHash` returns it. */
  leaf: Hex;
  /** Sibling hashes from the leaf up to the root, as `claim` expects them. */
  proof: Hex[];
}

/** The payout tree of one campaign. */
export interface PayoutTree {
  campaignId: bigint;
  /** The root passed to `settle`, or {@link EMPTY_ROOT} when there is no payout. */
  root: Hex;
  /** Leaves ordered by wallet address (ascending), each with its proof. */
  leaves: PayoutLeaf[];
}

/**
 * Hash of the payout leaf `(campaignId, wallet, amount)`, identical to
 * `MORCastEscrow.leafHash(campaignId, wallet, amount)`.
 */
export function payoutLeafHash(campaignId: bigint, wallet: Address, amount: bigint): Hex {
  return keccak256(keccak256(encodeAbiParameters(LEAF_PARAMETERS, [campaignId, wallet, amount])));
}

/**
 * Builds the payout tree of a campaign.
 *
 * Zero payouts are left out, because there is nothing to claim. Without any leaf, the root is
 * {@link EMPTY_ROOT}; the escrow accepts a zero root only when the creator pool is empty.
 *
 * @throws RangeError if the campaign ID or an amount is not a uint256, the campaign ID is zero,
 *         or a wallet is invalid or repeated.
 */
export function buildPayoutTree(campaignId: bigint, payouts: readonly Payout[]): PayoutTree {
  assertUint256(campaignId, "campaignId");
  if (campaignId === 0n) throw new RangeError("campaign IDs start at 1");
  validatePayouts(payouts);

  const values = payouts
    .filter((payout) => payout.amount > 0n)
    .sort((a, b) => (BigInt(a.wallet) < BigInt(b.wallet) ? -1 : 1));
  if (values.length === 0) return { campaignId, root: EMPTY_ROOT, leaves: [] };

  const tree = StandardMerkleTree.of(
    values.map(({ wallet, amount }) => [campaignId, wallet, amount]),
    [...PAYOUT_LEAF_ENCODING],
  );

  return {
    campaignId,
    root: tree.root as Hex,
    leaves: values.map(({ wallet, amount }, index) => ({
      wallet,
      amount,
      leaf: payoutLeafHash(campaignId, wallet, amount),
      // Index `index` of the values passed to StandardMerkleTree.of.
      proof: tree.getProof(index) as Hex[],
    })),
  };
}

/**
 * Checks a payout proof the same way `MerkleProof.verify` does in the escrow.
 *
 * Implemented independently of the tree library: starting from the leaf, each proof element is
 * combined with the running hash in sorted order.
 */
export function verifyPayoutProof(
  root: Hex,
  campaignId: bigint,
  wallet: Address,
  amount: bigint,
  proof: readonly Hex[],
): boolean {
  let hash = payoutLeafHash(campaignId, wallet, amount);
  for (const sibling of proof) hash = hashPair(hash, sibling);
  return hash.toLowerCase() === root.toLowerCase();
}

/** Inner node hash: keccak256 of the two child hashes, the smaller one first. */
export function hashPair(a: Hex, b: Hex): Hex {
  // Equal-length lowercase hex strings compare in the same order as the bytes they encode.
  const [first, second] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  return keccak256(concat([first, second]));
}

function validatePayouts(payouts: readonly Payout[]): void {
  const seen = new Set<string>();
  for (const { wallet, amount } of payouts) {
    if (!isAddress(wallet, { strict: false })) throw new RangeError(`invalid wallet ${wallet}`);
    const key = wallet.toLowerCase();
    if (seen.has(key)) throw new RangeError(`duplicate wallet ${wallet}`);
    seen.add(key);
    assertUint256(amount, `amount of ${wallet}`);
  }
}
