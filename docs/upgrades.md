# Versions and Upgrades

The escrow cannot be upgraded. A new version is a new deployment at a new address, and every deployment keeps running on its own.

## Identifying a Deployment

- `VERSION()` returns the version of a deployment's code, for example `"1.0.0"`, following semantic versioning. A new major version may change the ABI or the rules.
- Every deployment of one version runs identical code, because the contract has no immutable variables. Its runtime code hash therefore identifies the released code. The SDK publishes it as `ESCROW_CODE_HASH`, and `isGenuineEscrow(client, address)` checks a deployment. A contract with another hash is not that version's escrow, whatever its functions answer.
- A result dataset names its deployment with `chainId` and `escrow`. Campaign IDs restart at 1 in every deployment, so a campaign is identified by `(chainId, escrow, campaignId)`.
- The SDK implements one major version (`ESCROW_VERSION`). `morcast-verify --rpc-url` refuses deployments with a different major version rather than misreading them.

## Releasing a New Version

1. Deploy and verify the new version (see [Deployment](deployment.md)). The same owner, settler and treasury wallets can serve several versions.
2. Point new deposit requests to the new address.
3. On the previous version, the owner pauses campaign creation (`setCreationPaused(true)`), so no brand deposits there by mistake.
4. The previous version keeps running for its campaigns, with settlement between Day 5 and Day 10, refunds and claims. Claims never expire, so a deployment is never switched off.

Funds are never moved between versions. No function can move escrowed funds, so every campaign finishes on the deployment that holds it. A campaign's terms never change after its deposit.

## Off-Chain Requirements

Systems that work with Morcast campaigns must:

- identify every campaign by `(chainId, escrow, campaignId)`
- keep a registry of deployments with the address, version, deployment block, and whether new campaigns may use it
- index the events of every registered deployment
- show creators their unclaimed payouts from every deployment
- before registering a deployment or sending a deposit request for it, check that its code is genuine (`isGenuineEscrow`) and that its owner, settler and treasury are the operator's own addresses
- include the escrow address in the campaign manifest and the deposit request, so that each accepted campaign targets exactly one deployment
- read each deployment with the ABI of its major version.
