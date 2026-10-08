# Deployment

The escrow's code and economic rules cannot change after deployment. The owner can later replace the settler and the treasury and change which tokens new campaigns may use (see [owner actions](escrow.md#owner-actions)).

## Base Mainnet

Requirements: a funded deployer account (Foundry keystore, hardware wallet or other signer), the owner, settler and treasury addresses, and an Etherscan API key for source verification. The owner and the settler should be separate multisigs (for example Safe) with hardware signers. The deployer account gets no role in the contract.

```sh
export OWNER=0x...              # MORCast owner multisig
export SETTLER=0x...            # MORCast settlement multisig
export TREASURY=0x...           # MORCast fee recipient
export ETHERSCAN_API_KEY=...    # for --verify

forge script script/Deploy.s.sol \
  --rpc-url https://mainnet.base.org \
  --account <keystore-name> \
  --broadcast --verify
```

On Base mainnet the script always uses the canonical tokens. `USDC` and `MOR` may be left unset. If set, they must equal these addresses:

| Token | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| MOR | `0x7431aDa8a591C955a994a21710752EF9b882b8e3` |

After deployment, check:

- The code hash (`cast codehash <escrow>`) equals the SDK's `ESCROW_CODE_HASH`, so the deployment runs the released code.
- `owner()`, `settler()` and `treasury()` return the intended addresses, and `pendingOwner()` returns the zero address.
- `isCampaignToken(USDC)` and `isCampaignToken(MOR)` return `true`, `creationPaused()` returns `false`, and `VERSION()` returns the released version.
- `SETTLEMENT_OPENS_AFTER()` returns `432000` (5 days), `SETTLEMENT_CLOSES_AFTER()` returns `864000` (10 days) and `MAX_CAMPAIGN_DURATION()` returns `7776000` (90 days).
- The source is verified on Basescan.

## Other Networks

On every chain except Base mainnet, both token addresses are required:

```sh
export OWNER=0x... SETTLER=0x... TREASURY=0x... USDC=0x... MOR=0x...
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

- deploys mock USDC (6 decimals) and mock MOR (18 decimals), plus an escrow that accepts them
- mints 1,000,000 of each token to the brand account
- uses Anvil account 0 (the deployer) as owner, account 1 as settler, account 2 as treasury and account 3 as brand, unless `OWNER`, `SETTLER`, `TREASURY` or `BRAND` is set
- refuses to run on any chain other than Anvil (chain ID 31337).

On a fresh Anvil node, the addresses are always:

| Contract | Address |
|---|---|
| USDC (mock) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| MOR (mock) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| MORCastEscrow | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |

## Deployments

No production deployment yet. Staging (Base Sepolia, chain 84532) runs version `1.0.0`, deployed from `v1.0.0-rc.3` and verified on [Sourcify](https://sourcify.dev). Its transactions are recorded in [`broadcast/Deploy.s.sol/84532`](../broadcast/Deploy.s.sol/84532):

| Contract | Address |
|---|---|
| MORCastEscrow | [`0x7550A4093bF8883Faa437bd60DA4a7eC3591a1D7`](https://sepolia.basescan.org/address/0x7550A4093bF8883Faa437bd60DA4a7eC3591a1D7), created in block 47781042 |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (Circle's test USDC) |
| MOR (test) | `0x97f3Db60394c979c5ffB1345b62BDC3020Fb0459`: [`MockERC20`](../test/utils/Tokens.sol) "MorpheusAI (test)", 18 decimals. Anyone can mint it |

Its owner, settler and treasury are one staging operator account, `0xB0742AC9890BEf1894747724077254F9553Cd946`, which holds no real funds. Production uses separate multisigs, as above.
