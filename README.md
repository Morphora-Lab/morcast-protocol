# MORCast Payment Protocol

On-chain escrow and settlement for MORCast creator campaigns on Base.

A brand escrows a campaign budget in USDC or MOR. After the campaign ends, MORCast publishes the measured results and settles the campaign once. The contract then pays the protocol fee, lets creators claim their share against a Merkle root, and returns the unspent budget to the brand. If the campaign is not settled within its settlement window, the brand can withdraw the full budget.

## Status

Early development. Not deployed. Not audited.

| Component | State |
|---|---|
| Settlement arithmetic (`SettlementMath`) | Implemented and tested |
| Escrow contract | In progress |

## Documentation

- [Settlement arithmetic](docs/settlement.md): how the budget is split between fee, creator pool and refund.

## Development

Requirements: [Foundry](https://getfoundry.sh) 1.8 or later.

```sh
git clone --recurse-submodules https://github.com/Morphora-Lab/morcast-protocol.git
cd morcast-protocol
forge build
forge test
```

Dependencies are Git submodules pinned in `foundry.lock`: forge-std v1.17.0 and OpenZeppelin Contracts v5.7.0.

## License

[MIT](LICENSE)
