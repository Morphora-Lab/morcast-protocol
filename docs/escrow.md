# Escrow Contract

[`MORCastEscrow`](../src/MORCastEscrow.sol) holds campaign budgets, settles each campaign once from the recognized total, and pays out the protocol fee, creator claims and the brand refund. Events and errors are defined in [`IMORCastEscrow`](../src/interfaces/IMORCastEscrow.sol).

## Roles

| Role | Address | Powers |
|---|---|---|
| Brand | Caller of `createCampaign` | Cancel before the start. Withdraw the refund after settlement. Withdraw the whole budget from Day 10 if the campaign was not settled. |
| Settler | Set at deployment; replaceable by the owner | Settle each campaign once, inside `[Day 5, Day 10)`. No other power. |
| Treasury | Set at deployment; replaceable by the owner | Receives protocol fees. |
| Owner | Set at deployment; transferred in two steps | Operate the escrow (see [Owner Actions](#owner-actions)). The owner can never move a campaign's money anywhere except back to the brand that deposited it. |
| Anyone | Any address | Submit a creator claim (funds always go to the leaf's wallet). Trigger the fee transfer to the treasury. |

The code cannot be upgraded, and the economic rules (the formula, the 20% fee, Day 5, Day 10 and the 90-day maximum) are constants. A new version is a new deployment.

## Timeline

`Day N` means `endAt + N × 86,400` seconds.

| Action | Allowed when |
|---|---|
| `createCampaign`, `cancel` | `t < startAt` |
| Campaign window | `startAt ≤ t < endAt`, at most 90 days long (`MAX_CAMPAIGN_DURATION`) |
| `settle` | `Day 5 ≤ t < Day 10` |
| `withdrawBrand` of an unsettled campaign | `t ≥ Day 10` |
| `voidCampaign` (owner) | Any time while the campaign is funded |
| `claim`, `withdrawFee`, `withdrawBrand` of a settled campaign | Any time after settlement. Entitlements never expire. |

```text
createCampaign ─► Funded ─┬─ cancel (t < startAt) ──────────► Cancelled
                          ├─ settle (Day 5 <= t < Day 10) ─► Settled
                          ├─ withdrawBrand (t >= Day 10) ──► Refunded
                          └─ voidCampaign (owner) ─────────► Refunded
```

## Functions

| Function | Caller | Conditions | Effect |
|---|---|---|---|
| `createCampaign(token, budget, target, startAt, endAt, manifestHash)` | brand | Creation is not paused. `token` is allowed. `budget > 0` and `budget mod 5 == 0`. `target > 0`. `startAt < endAt` and `endAt − startAt ≤ 90 days`. `t < startAt`. The escrow's balance rises by exactly `budget`. | Pulls `budget`. Status `Funded`. Returns the new campaign ID. |
| `cancel(id)` | brand | `Funded` and `t < startAt` | Status `Cancelled`. The budget goes to the brand. |
| `settle(id, recognized, merkleRoot, resultHash)` | settler | `Funded` and `Day 5 ≤ t < Day 10`. `merkleRoot ≠ 0` when the pool is not empty. `resultHash ≠ 0`. | Computes spent, fee, pool and refund with the [settlement formula](settlement.md). Status `Settled`. |
| `claim(id, wallet, amount, proof)` | anyone | `Settled`. The leaf is proven against `merkleRoot` and not yet claimed. `amount ≤ pool − creatorClaimed`. | Marks the leaf claimed. `amount` goes to `wallet`. |
| `withdrawFee(id)` | anyone | `Settled` and the fee not yet paid | The fee goes to the current treasury. |
| `withdrawBrand(id)` | brand | `Settled` and the refund not yet paid, **or** `Funded` and `t ≥ Day 10` | The refund goes to the brand, **or** the whole budget goes to the brand and the status becomes `Refunded`. |

## Owner Actions

The owner should be a multisig. Every action emits an event.

| Function | Effect | Effect on existing campaigns |
|---|---|---|
| `setSettler(address)` | Replaces the settler. The zero address disables settlement. | The new settler settles them. With settlement disabled, they fall back to the Day-10 refund. |
| `setTreasury(address)` | Replaces the fee recipient | Fees withdrawn from then on go to the new treasury. |
| `setCampaignToken(token, allowed)` | Allows or disallows a token for new campaigns | None |
| `setCreationPaused(paused)` | Pauses or resumes `createCampaign` | None: cancellation, settlement, claims and refunds keep working. |
| `voidCampaign(id)` | Ends a funded campaign; its whole budget goes back to its brand. | Only the voided campaign |
| `recoverTokens(token, to)` | Sends `to` the tokens held beyond `totalOwed(token)`, such as tokens transferred to the escrow by mistake | None: campaign funds cannot be recovered. |
| `transferOwnership(address)`, `acceptOwnership()` | Two-step ownership transfer: the new owner must accept | None |

`renounceOwnership()` removes the owner permanently. The settler, treasury and allowed tokens then stay fixed, and the pause, voiding and recovery become unavailable.

## Creator Payouts

Each creator payout is one Merkle leaf:

```text
leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256 campaignId, address wallet, uint256 amount))))
```

This is the OpenZeppelin `StandardMerkleTree` leaf format for the value types `(uint256, address, uint256)`. Inner nodes hash their two children in sorted order, which is what `MerkleProof` expects. Because the campaign ID is part of the leaf, a proof for one campaign can never pay out of another. The full tree construction is specified in [Hashing and Merkle trees](hashing.md).

## Security Properties

- Each campaign has its own accounting. A campaign never pays out more than its own budget.
- `fee + pool + refund = budget`. Creator claims never exceed `pool`, and each leaf can be claimed once.
- `totalOwed(token)` always equals what the campaigns in that token are still owed, and the escrow's balance is never below it.
- The owner can send a campaign's funds only back to its brand (`voidCampaign`). No function lets any role take escrowed funds.
- A deposit must raise the escrow's balance by exactly `budget`, which rejects tokens with transfer fees.
- State changes and events happen before every token transfer. Transfers use `SafeERC20`, and every function that moves tokens has a reentrancy guard.
- Settlement is final. There is no correction path.
- If the token refuses a transfer to an address (for example, a USDC-blacklisted wallet), that payout stays in the escrow. There is no way to redirect it.

## Deployment Settings

| Setting | Base mainnet |
|---|---|
| Campaign tokens | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Circle-issued, 6 decimals, not bridged USDbC) and MOR `0x7431aDa8a591C955a994a21710752EF9b882b8e3` (Morpheus MOR, 18 decimals) |
| Owner | MORCast multisig |
| Settler | MORCast settlement multisig |
| Treasury | MORCast fee recipient |
