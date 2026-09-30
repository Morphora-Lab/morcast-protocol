# Escrow Contract

[`MORCastEscrow`](../src/MORCastEscrow.sol) holds campaign budgets, settles each campaign once from the recognized total, and pays out the protocol fee, creator claims and the brand refund. Events and errors are defined in [`IMORCastEscrow`](../src/interfaces/IMORCastEscrow.sol).

## Roles

| Role | Address | Powers |
|---|---|---|
| Brand | Caller of `createCampaign` | Cancel before the start. Withdraw the refund after settlement. Withdraw the whole budget from Day 10 if the campaign was not settled. |
| Settler | Fixed at deployment | Settle each campaign once, inside `[Day 5, Day 10)`. No other power. |
| Treasury | Fixed at deployment | Receives protocol fees. |
| Anyone | Any address | Submit a creator claim (funds always go to the leaf's wallet). Trigger the fee transfer to the treasury. |

The contract has no owner, no pause and no upgrade path. Changing a deployment setting requires a new deployment, and existing campaigns are unaffected.

## Timeline

`Day N` means `endAt + N × 86,400` seconds.

| Action | Allowed when |
|---|---|
| `createCampaign`, `cancel` | `t < startAt` |
| `settle` | `Day 5 ≤ t < Day 10` |
| `withdrawBrand` of an unsettled campaign | `t ≥ Day 10` |
| `claim`, `withdrawFee`, `withdrawBrand` of a settled campaign | Any time after settlement. Entitlements never expire. |

```text
createCampaign ─► Funded ─┬─ cancel (t < startAt) ──────────► Cancelled
                          ├─ settle (Day 5 <= t < Day 10) ─► Settled
                          └─ withdrawBrand (t >= Day 10) ──► Refunded
```

## Functions

| Function | Caller | Conditions | Effect |
|---|---|---|---|
| `createCampaign(token, budget, target, startAt, endAt, manifestHash)` | brand | `token` is USDC or MOR. `budget > 0` and `budget mod 5 == 0`. `target > 0`. `startAt < endAt`. `t < startAt`. The escrow's balance rises by exactly `budget`. | Pulls `budget`. Status `Funded`. Returns the new campaign ID. |
| `cancel(id)` | brand | `Funded` and `t < startAt` | Status `Cancelled`. The budget goes to the brand. |
| `settle(id, recognized, merkleRoot, resultHash)` | settler | `Funded` and `Day 5 ≤ t < Day 10`. `merkleRoot ≠ 0` when the pool is not empty. `resultHash ≠ 0`. | Computes spent, fee, pool and refund with the [settlement formula](settlement.md). Status `Settled`. |
| `claim(id, wallet, amount, proof)` | anyone | `Settled`. The leaf is proven against `merkleRoot` and not yet claimed. `amount ≤ pool − creatorClaimed`. | Marks the leaf claimed. `amount` goes to `wallet`. |
| `withdrawFee(id)` | anyone | `Settled` and the fee not yet paid | The fee goes to the treasury. |
| `withdrawBrand(id)` | brand | `Settled` and the refund not yet paid, **or** `Funded` and `t ≥ Day 10` | The refund goes to the brand, **or** the whole budget goes to the brand and the status becomes `Refunded`. |

## Creator Payouts

Each creator payout is one Merkle leaf:

```text
leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256 campaignId, address wallet, uint256 amount))))
```

This is the OpenZeppelin `StandardMerkleTree` leaf format for the value types `(uint256, address, uint256)`. Inner nodes hash their two children in sorted order, which is what `MerkleProof` expects. Because the campaign ID is part of the leaf, a proof for one campaign can never pay out of another.

## Security Properties

- Each campaign has its own accounting. A campaign never pays out more than its own budget.
- `fee + pool + refund = budget`. Creator claims never exceed `pool`, and each leaf can be claimed once.
- Only USDC and MOR are accepted. The deposit check rejects any token that delivers less than `budget`.
- State changes and events happen before every token transfer. Transfers use `SafeERC20`, and every function that moves tokens has a reentrancy guard.
- Settlement is final. There is no correction path.
- If the token refuses a transfer to an address (for example, a USDC-blacklisted wallet), that payout stays in the escrow. There is no way to redirect it.

## Deployment Settings

| Setting | Base mainnet |
|---|---|
| `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`: Circle-issued USDC, 6 decimals (not bridged USDbC) |
| `MOR` | `0x7431aDa8a591C955a994a21710752EF9b882b8e3`: Morpheus MOR, 18 decimals |
| `SETTLER` | MORCast settlement address |
| `TREASURY` | MORCast fee recipient |
