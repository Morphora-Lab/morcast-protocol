# Security

## Status

| Item | State |
|---|---|
| Internal review | Completed 2026-09-30 on commit `45a7bc4`. No critical, high or medium findings. S-2 has since been fixed. |
| External audit | Not yet performed. Required before mainnet deployment. |
| Deployment | None |

Please report vulnerabilities privately through GitHub's "Report a vulnerability" form on this repository, not in public issues.

## Trust Model

| Party | Trusted to | Cannot |
|---|---|---|
| Settler (MORCast) | Settle each campaign with the recognized total and payout tree of the published result dataset | Settle outside `[Day 5, Day 10)` or twice; change the fee recipient or the refund recipient; move escrowed funds in any other way |
| Brand | Nothing beyond its own campaign's parameters | Cancel after `startAt`; withdraw before settlement or Day 10; affect other campaigns |
| Creators and anyone else | Nothing | Claim anything but an existing, unclaimed leaf; redirect a payout |
| Token issuers | Circle (USDC) can pause transfers and blacklist addresses | MOR on Base (`MOROFT`, not upgradeable) has no pause, blacklist or transfer fee |

Base's sequencer orders transactions and sets timestamps. Deadlines are whole days, so timestamp drift has no practical effect. If the chain is unavailable for the whole settlement window, the campaign falls back to the full refund.

## Review Scope and Method

- **Code:** `src/MORCastEscrow.sol`, `src/libraries/SettlementMath.sol`, `src/interfaces/IMORCastEscrow.sol`.
- **Manual review:** access control, the status machine, reentrancy and call ordering, arithmetic and rounding, Merkle proofs and leaf encoding, token behaviour, deadlines, isolation between campaigns, and denial of service.
- **Static analysis:**
  - Slither 0.11.6 (all 76 detectors), Aderyn 0.6.8 and the Foundry linter;
  - Solidity 0.8.37 has no known compiler bugs;
  - no OpenZeppelin Contracts advisory affects the modules used (`SafeERC20`, `MerkleProof`, `Math`, `ReentrancyGuardTransient`).
- **Tests:**
  - unit tests with 100% line coverage, and fuzz tests;
  - invariant tests: 51,200 random calls per CI run;
  - Base mainnet fork tests with the real USDC and MOR;
  - the local end-to-end run;
  - the attack scenarios in [`test/Security.t.sol`](../test/Security.t.sol).

## Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| S-1 | Centralization | The settler decides `S` and the payout tree | By design; mitigated operationally |
| S-2 | Low | No upper bound on the campaign schedule | Fixed: 90-day maximum |
| S-3 | Low | The USDC issuer can freeze transfers | Accepted |
| S-4 | Informational | A wrong payout tree cannot be corrected | Mitigated off-chain |
| S-5 | Informational | Tokens sent directly to the escrow are locked | Accepted |
| S-6 | Informational | Transient storage is required | Accepted |
| S-7 | Informational | Campaign IDs are assigned at execution | Documented for integrators |
| S-8 | Informational | Tool warnings | Acknowledged |

### S-1: The settler decides `S` and the payout tree

For every campaign inside its settlement window, a compromised or dishonest settler can choose any recognized total (up to spending the whole budget) and any Merkle root. That sends up to the creator pool, 80% of the budget, to wallets of its choice. The fee still goes to the fixed treasury and the refund to the brand. This is the protocol's trust model: MORCast is the single trusted verifier.

Mitigations:
- Use a multisig with hardware signers as the settler.
- Settle only from a published dataset that passes `morcast-verify`.
- Monitor every `CampaignSettled` event against the published datasets.

### S-2: No upper bound on the campaign schedule

`createCampaign` accepts any `startAt < endAt`. Once `startAt` has passed, the brand cannot cancel, and an unsettled budget returns only from `endAt + 10 days`. A mistaken `endAt`, for example milliseconds instead of seconds, would lock the budget for thousands of years.

Fixed: `createCampaign` rejects campaigns longer than `MAX_CAMPAIGN_DURATION` (90 days), so a mistaken `endAt` fails at creation. A lead time before `startAt` needs no limit, because the brand can cancel at any time before the start.

### S-3: The USDC issuer can freeze transfers

If Circle pauses USDC, every USDC campaign is blocked until the pause ends. A blacklisted creator, brand or treasury cannot receive its payout. A blacklisted escrow would freeze all USDC campaigns. By design there is no recovery or reassignment path. MOR is not affected.

### S-4: A wrong payout tree cannot be corrected

The contract checks proofs, not the contents of the tree. If the leaves add up to less than the pool, or pay an address that can never receive (the zero address or the escrow itself), the difference stays locked, because settlement is final.

Mitigations:
- The SDK refuses zero-address payouts.
- The verifier rejects creator wallets equal to the zero address or the escrow.
- The platform must verify the dataset before calling `settle`.

Leaves that add up to more than the pool are harmless: claims stop at the pool.

### S-5: Tokens sent directly to the escrow are locked

Tokens transferred to the escrow other than through `createCampaign` cannot be withdrawn, because the contract has no administrator. They do not affect any campaign's accounting.

### S-6: Transient storage is required

The reentrancy guard uses EIP-1153 transient storage. Deploy only to chains with the Cancun instruction set. Base supports it, and the fork tests run there.

### S-7: Campaign IDs are assigned at execution

Concurrent `createCampaign` transactions can change which ID a campaign receives. Off-chain systems must read the ID from the `CampaignCreated` event of the brand's transaction, not predict it.

### S-8: Tool warnings

| Tool | Warning | Assessment |
|---|---|---|
| Slither | `timestamp` | Every deadline is a whole number of days. |
| Slither | `naming-convention` | Constants and immutables use upper case, as the Foundry linter requires. |
| Aderyn | PUSH0 opcode | Supported on Base. |
| Aderyn | Floating pragma | Only in the interface and the library, so integrators can import them. The contract is pinned to 0.8.37. |

## Verified Properties

| Property | Evidence |
|---|---|
| Only the brand cancels or withdraws its funds; only the settler settles; funds go only to leaf wallets, the treasury or the brand | Unit tests |
| A campaign never pays out more than its budget: `fee + pool + refund = budget`, and claims never exceed the pool | Invariant suite; `SettlementMath` fuzz tests; duplicate-leaf test |
| The escrow's balance always equals its outstanding obligations across all campaigns | Invariant suite |
| At every moment exactly one of settlement and the full refund is possible | `testFuzz_settlementAndRefundAreMutuallyExclusive` |
| A proof is valid for one campaign only; each leaf is paid once; front-running a claim is harmless | Unit tests; `test_frontRunClaimPaysCreatorOnce` |
| A brand's approval cannot be spent by anyone else | `test_brandApprovalCannotBeSpentByOthers` |
| A token callback cannot re-enter the escrow, and a relayer can batch claims | Reentrancy test; `test_relayerCanBatchClaimsInOneTransaction` |
| A deposit must deliver exactly the budget | Fee-on-transfer test |
| No campaign can last longer than 90 days, so a mistaken `endAt` cannot lock a budget | `test_createCampaign_rejectsEndAtInMilliseconds` and the duration tests |
| The real USDC and MOR contracts behave as expected | Base fork tests |
