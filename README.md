# MORCast Payment Protocol

On-chain escrow and settlement for MORCast creator campaigns on Base.

A brand escrows a campaign budget in USDC or MOR. After the campaign ends, MORCast publishes the measured results and settles the campaign once. The contract then pays the protocol fee, lets creators claim their share against a Merkle root, and returns the unspent budget to the brand. If the campaign is not settled within its settlement window, the brand can withdraw the full budget.

## Status

Early development. Not deployed. Not audited.

| Component | State |
|---|---|
| Escrow contract (`MORCastEscrow`) | Implemented; unit, invariant and Base fork tests |
| Settlement arithmetic (`SettlementMath`) | Implemented, unit- and fuzz-tested |
| Deployment scripts | Implemented; not yet deployed |
| TypeScript SDK: settlement, payouts, metrics | Implemented, tested against the shared vectors |
| TypeScript SDK: document hashing, payout Merkle trees | Implemented; trees verified against the contract |
| TypeScript SDK: result dataset and verifier | Planned |

## Usage

A brand approves the escrow for the budget and creates the campaign:

```solidity
IERC20(usdc).approve(address(escrow), budget);
uint256 id = escrow.createCampaign(usdc, budget, target, startAt, endAt, manifestHash);
```

Between Day 5 and Day 10 after `endAt`, the settler settles the campaign with the recognized total from the published result dataset:

```solidity
escrow.settle(id, recognized, merkleRoot, resultHash);
```

Then each party collects its share:

```solidity
escrow.claim(id, wallet, amount, proof); // creator payout; anyone may submit it
escrow.withdrawFee(id);                  // protocol fee to the treasury; anyone may call it
escrow.withdrawBrand(id);                // unspent budget back to the brand
```

If the campaign is not settled before Day 10, the brand calls `withdrawBrand(id)` from Day 10 to recover the whole budget.

## Example

A brand escrows 100,000 USDC for a target of 1,000,000 qualified views, and MORCast recognizes 640,000:

| Party | Receives |
|---|---|
| MORCast treasury (fee, 20% of spent) | 12,800 USDC |
| Creators (pool, 80% of spent) | 51,200 USDC |
| Brand (refund) | 36,000 USDC |

The brand pays for 64% of the target, so 64,000 USDC is spent.

## Documentation

- [Escrow contract](docs/escrow.md): roles, timeline, functions, payout leaves and security properties.
- [Settlement arithmetic](docs/settlement.md): creator scores, the budget split and creator payouts.
- [Metrics](docs/metrics.md): exact decimals and the Integration retention metric.
- [Hashing and Merkle trees](docs/hashing.md): canonical JSON for `manifestHash` and `resultHash`, and payout tree construction.
- [Deployment](docs/deployment.md): deploying to Base mainnet, other networks and a local Anvil node.
- [TypeScript SDK](sdk/README.md): the protocol arithmetic for off-chain services and verifiers.

## Development

Requirements: [Foundry](https://getfoundry.sh) 1.8 or later.

```sh
git clone --recurse-submodules https://github.com/Morphora-Lab/morcast-protocol.git
cd morcast-protocol
forge build
forge test
```

Dependencies are Git submodules pinned in `foundry.lock`: forge-std v1.17.0 and OpenZeppelin Contracts v5.7.0.

The TypeScript SDK lives in [`sdk/`](sdk) and has its own [instructions](sdk/README.md#development).

### Tests

| Suite | Location | Checks |
|---|---|---|
| Unit | `test/*.t.sol` | Every function, revert path and time boundary. |
| Fuzz | `testFuzz_*` functions | Settlement and payout properties for random inputs. |
| Invariant | `test/invariant/` | Across random multi-campaign sequences: escrow balances equal outstanding obligations, and settled campaigns follow the formula. |
| Fork | `test/fork/` | Full lifecycle with the real USDC and MOR contracts on Base mainnet. Skipped unless `BASE_RPC_URL` is set. |
| Vectors | `vectors/` | Numeric examples from the specification, shared with off-chain implementations. |

```sh
forge test                                              # unit, fuzz and invariant tests
BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"
```

## License

[MIT](LICENSE)
