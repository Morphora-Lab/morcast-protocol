# MORCast Payment Protocol

On-chain escrow and settlement for MORCast creator campaigns on Base.

A brand escrows a campaign budget in USDC or MOR. After the campaign ends, MORCast publishes the measured results and settles the campaign once. The contract then pays the protocol fee, lets creators claim their share against a Merkle root, and returns the unspent budget to the brand. If the campaign is not settled within its settlement window, the brand can withdraw the full budget.

## Status

Early development. Not deployed. Not audited.

## License

[MIT](LICENSE)
