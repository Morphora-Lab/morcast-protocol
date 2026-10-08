# Security

## Status

| Item | State |
|---|---|
| Internal review | Completed 2026-09-30 on commit `45a7bc4`, and extended the same day to the owner role. No critical, high or medium findings. |
| External audit | Not yet performed. Required before mainnet deployment. |
| Deployment | None |

Please report vulnerabilities privately through GitHub's "Report a vulnerability" form on this repository, not in public issues.

## Trust Model

| Party | Trusted to | Cannot |
|---|---|---|
| Owner (MORCast's owner wallet) | Replace the settler and the treasury. Choose tokens and pause creation for new campaigns. Void funded campaigns. Recover stray tokens | Move a campaign's funds anywhere except back to its brand. Change the formula, the fee, the deadlines or the 90-day maximum. Change a settlement |
| Settler (MORCast's settler wallet) | Settle each campaign with the recognized total and payout tree of the published result dataset | Settle outside `[Day 5, Day 10)` or twice. Change the fee recipient or the refund recipient. Move escrowed funds in any other way |
| Brand | Nothing beyond its own campaign's parameters | Cancel after `startAt`. Withdraw before settlement or Day 10. Affect other campaigns |
| Creators and anyone else | Nothing | Claim anything but an existing, unclaimed leaf. Redirect a payout |
| Token issuers | Circle (USDC) can pause transfers and blacklist addresses | MOR on Base (`MOROFT`, not upgradeable) has no pause, blacklist or transfer fee |

Base's sequencer orders transactions and sets timestamps. Deadlines are whole days, so timestamp drift has no practical effect. If the chain is unavailable for the whole settlement window, the campaign falls back to the full refund.

## Review Scope and Method

- **Code:** `src/MORCastEscrow.sol`, `src/libraries/SettlementMath.sol`, `src/interfaces/IMORCastEscrow.sol`.
- **Manual review:** access control, the status machine, reentrancy and call ordering, arithmetic and rounding, Merkle proofs and leaf encoding, token behaviour, deadlines, isolation between campaigns, owner powers, and denial of service.
- **Static analysis:**
  - Slither 0.11.6 (all detectors), Aderyn 0.6.8 and the Foundry linter
  - Solidity 0.8.37 has no known compiler bugs
  - no OpenZeppelin Contracts advisory affects the modules used (`Ownable2Step`, `SafeERC20`, `MerkleProof`, `Math`, `ReentrancyGuardTransient`).
- **Tests:**
  - unit tests with 100% line coverage, and fuzz tests
  - invariant tests: 51,200 random calls per CI run, including every owner action
  - Base mainnet fork tests with the real USDC and MOR
  - the local end-to-end run
  - the attack scenarios in [`test/Security.t.sol`](../test/Security.t.sol).

## Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| S-1 | Centralization | The owner and the settler are trusted | By design. Mitigated operationally |
| S-2 | Low | No upper bound on the campaign schedule | Fixed: 90-day maximum |
| S-3 | Low | The USDC issuer can freeze transfers | Accepted |
| S-4 | Informational | A wrong payout tree cannot be corrected | Mitigated off-chain |
| S-5 | Informational | Tokens sent directly to the escrow are locked | Fixed: `recoverTokens` |
| S-6 | Informational | Transient storage is required | Accepted |
| S-7 | Informational | Campaign IDs are assigned at execution | Documented for integrators |
| S-8 | Informational | Tool warnings | Acknowledged |
| S-9 | Informational | The owner can void a running campaign | By design. Governed by policy |

### S-1: The owner and the settler are trusted

For every campaign inside its settlement window, a compromised or dishonest settler can choose any recognized total (up to spending the whole budget) and any Merkle root. That sends up to the creator pool, 80% of the budget, to wallets of its choice. The fee still goes to the treasury and the refund to the brand.

The owner can appoint the settler, so a compromised owner has the same reach. In addition, it can void funded campaigns (their budgets go back to the brands) and redirect future fee withdrawals. Neither role can take escrowed funds in any other way. This is the protocol's trust model, with MORCast as the single trusted verifier.

Mitigations:
- Keep the owner and the settler in separate wallets, with their keys on hardware signers.
- Settle only from a published dataset that passes `morcast-verify`.
- Monitor every `CampaignSettled` event against the published datasets, and every owner event (`SettlerUpdated`, `TreasuryUpdated`, `CampaignTokenUpdated`, `CreationPausedUpdated`, `CampaignVoided`, `TokensRecovered`, ownership transfers).

### S-2: No upper bound on the campaign schedule

`createCampaign` accepted any `startAt < endAt`. Once `startAt` has passed, the brand cannot cancel, and an unsettled budget returns only from `endAt + 10 days`. A mistaken `endAt`, for example milliseconds instead of seconds, would have locked the budget for thousands of years.

Fixed. `createCampaign` rejects campaigns longer than `MAX_CAMPAIGN_DURATION` (90 days), so a mistaken `endAt` fails at creation. A lead time before `startAt` needs no limit, because the brand can cancel at any time before the start. The owner can also void a campaign created by mistake.

### S-3: The USDC issuer can freeze transfers

If Circle pauses USDC, every USDC campaign is blocked until the pause ends. A blacklisted creator, brand or treasury cannot receive its payout. A blacklisted escrow would freeze all USDC campaigns. There is no path to reassign a payout. MOR is not affected.

### S-4: A wrong payout tree cannot be corrected

The contract checks proofs, not the contents of the tree. If the leaves add up to less than the pool, or pay an address that can never receive (the zero address or the escrow itself), the difference stays locked, because settlement is final.

Mitigations:
- The SDK refuses zero-address payouts.
- The verifier rejects creator wallets equal to the zero address or the escrow.
- The platform must verify the dataset before calling `settle`.

Leaves that add up to more than the pool are harmless, because claims stop at the pool.

### S-5: Tokens sent directly to the escrow were locked

Tokens transferred to the escrow other than through `createCampaign` could not be withdrawn. They never affected any campaign's accounting.

Fixed. The escrow tracks `totalOwed` per token, and the owner's `recoverTokens` returns only the balance above it. Campaign funds cannot be recovered.

### S-6: Transient storage is required

The reentrancy guard uses EIP-1153 transient storage. Deploy only to chains with the Cancun instruction set. Base supports it, and the fork tests run there.

### S-7: Campaign IDs are assigned at execution

Concurrent `createCampaign` transactions can change which ID a campaign receives. Off-chain systems must read the ID from the `CampaignCreated` event of the brand's transaction, not predict it.

### S-8: Tool warnings

| Tool | Warning | Assessment |
|---|---|---|
| Slither | `timestamp` | Every deadline is a whole number of days. |
| Slither | `naming-convention` | Constants use upper case, as the Foundry linter requires. |
| Slither | `incorrect-equality` (`excess == 0` in `recoverTokens`) | Extra tokens only make more tokens recoverable. The check cannot block anything or reach campaign funds. |
| Aderyn | Centralization risk | The owner role. See S-1. |
| Aderyn | Address state variable set without checks | `setSettler` accepts the zero address on purpose, because that disables settlement. |
| Aderyn | Uninitialized local variable | A loop counter that starts at zero (`for (uint256 i; ...)`). |
| Aderyn | PUSH0 opcode | Supported on Base. |
| Aderyn | Floating pragma | Only in the interface and the library, so integrators can import them. The contract is pinned to 0.8.37. |

### S-9: The owner can void a running campaign

The owner can void a funded campaign at any time, including after creators have posted their content. The budget goes back to the brand only, so nothing can be stolen, but creators lose the payout they were working toward. Voiding must follow MORCast's published policy, for example for a mistaken deposit, a cancellation agreed with the brand before creators start, or an emergency.

## Verified Properties

| Property | Evidence |
|---|---|
| Only the brand cancels or withdraws its funds. Only the settler settles. Campaign funds go only to leaf wallets, the treasury or the brand | Unit tests |
| Only the owner can call owner actions, and an ownership transfer must be accepted | Owner tests |
| The owner cannot take campaign funds. Voiding pays only the brand, and recovery returns only tokens beyond `totalOwed` | `test_voidCampaign_returnsBudgetToBrand`, `test_recoverTokens_cannotTouchCampaignFunds`, invariant suite |
| Pausing creation or disallowing a token never blocks existing campaigns | `test_pause_blocksOnlyCampaignCreation`, `test_disallowedToken_blocksOnlyNewCampaigns` |
| A campaign never pays out more than its budget, since `fee + pool + refund = budget` and claims never exceed the pool | Invariant suite. `SettlementMath` fuzz tests. Duplicate-leaf test |
| `totalOwed` always equals the outstanding obligations of all campaigns, and the balance equals `totalOwed` plus stray tokens | Invariant suite |
| At every moment exactly one of settlement and the full refund is possible | `testFuzz_settlementAndRefundAreMutuallyExclusive` |
| A proof is valid for one campaign only. Each leaf is paid once. Front-running a claim is harmless | Unit tests. `test_frontRunClaimPaysCreatorOnce` |
| A brand's approval cannot be spent by anyone else | `test_brandApprovalCannotBeSpentByOthers` |
| A token callback cannot re-enter the escrow, and a relayer can batch claims | Reentrancy test. `test_relayerCanBatchClaimsInOneTransaction` |
| A deposit must deliver exactly the budget | Fee-on-transfer test |
| No campaign can last longer than 90 days, so a mistaken `endAt` cannot lock a budget | `test_createCampaign_rejectsEndAtInMilliseconds` and the duration tests |
| The real USDC and MOR contracts behave as expected | Base fork tests |
