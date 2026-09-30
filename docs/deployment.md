# Deployment

The escrow's settings (`SETTLER`, `TREASURY`, `USDC`, `MOR`) are fixed at deployment and cannot be changed. Changing any of them requires a new deployment. Campaigns on an earlier deployment are unaffected.

## Base Mainnet

Requirements: a funded deployer account (Foundry keystore, hardware wallet or other signer), the settler and treasury addresses, and an Etherscan API key for source verification.

```sh
export SETTLER=0x...            # MORCast settlement address (wallet or multisig)
export TREASURY=0x...           # MORCast fee recipient
export ETHERSCAN_API_KEY=...    # for --verify

forge script script/Deploy.s.sol \
  --rpc-url https://mainnet.base.org \
  --account <keystore-name> \
  --broadcast --verify
```

On Base mainnet the script always uses the canonical tokens. `USDC` and `MOR` may be left unset; if set, they must equal these addresses:

| Token | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| MOR | `0x7431aDa8a591C955a994a21710752EF9b882b8e3` |

After deployment, check:

- `SETTLER()`, `TREASURY()`, `USDC()` and `MOR()` return the intended addresses.
- `SETTLEMENT_OPENS_AFTER()` returns `432000` (5 days) and `SETTLEMENT_CLOSES_AFTER()` returns `864000` (10 days).
- The source is verified on Basescan.

## Other Networks

On every chain except Base mainnet, both token addresses are required:

```sh
export SETTLER=0x... TREASURY=0x... USDC=0x... MOR=0x...
forge script script/Deploy.s.sol --rpc-url <rpc-url> --account <keystore-name> --broadcast
```

## Local Development

```sh
anvil

forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

The private key is Anvil's default account 0. The script:

- deploys mock USDC (6 decimals) and mock MOR (18 decimals), plus an escrow that accepts them;
- mints 1,000,000 of each token to the brand account;
- uses Anvil account 1 as settler, account 2 as treasury and account 3 as brand, unless `SETTLER`, `TREASURY` or `BRAND` is set;
- refuses to run on any chain other than Anvil (chain ID 31337).

On a fresh Anvil node, the addresses are always:

| Contract | Address |
|---|---|
| USDC (mock) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| MOR (mock) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| MORCastEscrow | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |

## Deployments

None yet.
