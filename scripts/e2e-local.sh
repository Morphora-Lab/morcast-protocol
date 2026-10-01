#!/usr/bin/env bash
# End-to-end check on a local Anvil node, using the example result dataset:
#
#   1. deploy mock tokens and the escrow (script/DeployLocal.s.sol) and check that the escrow's
#      code hash is the SDK's ESCROW_CODE_HASH;
#   2. create the example campaign as the brand;
#   3. verify the dataset against the funded campaign;
#   4. move to Day 5 and settle with the dataset's S, Merkle root and resultHash;
#   5. verify the dataset against the settled campaign;
#   6. claim every payout with proofs from the SDK and check the creator balances.
#
# Requirements: Foundry, Node.js, jq, and a built SDK (cd sdk && pnpm build).
# Usage: scripts/e2e-local.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8546
RPC="http://127.0.0.1:${PORT}"
DATASET=examples/result-dataset.json
VERIFY="node sdk/dist/bin.js"

# Default Anvil keys: account 0 deploys, account 1 is the settler, account 3 is the brand.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SETTLER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BRAND_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

# Addresses produced by DeployLocal on a fresh node (see docs/deployment.md).
USDC=0x5FbDB2315678afecb367f032d93F642f64180aa3
ESCROW=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0

# The example campaign has fixed times, and a campaign can only be created before it starts. The
# node therefore starts one day before the campaign instead of at the current time, so the check
# gives the same result on any date.
genesis=$(( $(jq -r .campaign.startAt "$DATASET") - 86400 ))
anvil --port "$PORT" --silent --timestamp "$genesis" &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

step() { printf '\n==> %s\n' "$1"; }

step "Deploy"
forge script script/DeployLocal.s.sol --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast >/dev/null

step "Check that the deployment runs the released code"
# Runs in sdk/, where the SDK's dependencies (viem) resolve.
(cd sdk && node --input-type=module -e "
  import { createPublicClient, http } from 'viem';
  import { isGenuineEscrow } from './dist/index.js';
  const client = createPublicClient({ transport: http('$RPC') });
  if (!(await isGenuineEscrow(client, '$ESCROW'))) throw new Error('escrow code differs from ESCROW_CODE_HASH');
  if (await isGenuineEscrow(client, '$USDC')) throw new Error('a token passed as the escrow');
  console.log('escrow code hash matches ESCROW_CODE_HASH');
")

step "Create the example campaign"
budget=$(jq -r .campaign.budget "$DATASET")
cast send "$USDC" "approve(address,uint256)" "$ESCROW" "$budget" \
  --private-key "$BRAND_KEY" --rpc-url "$RPC" >/dev/null
cast send "$ESCROW" "createCampaign(address,uint256,uint256,uint64,uint64,bytes32)" "$USDC" \
  "$budget" "$(jq -r .campaign.target "$DATASET")" \
  "$(jq -r .campaign.startAt "$DATASET")" "$(jq -r .campaign.endAt "$DATASET")" \
  "$(jq -r .campaign.manifestHash "$DATASET")" \
  --private-key "$BRAND_KEY" --rpc-url "$RPC" >/dev/null

step "Verify against the funded campaign"
$VERIFY "$DATASET" --rpc-url "$RPC"

step "Settle on Day 5"
day5=$(( $(jq -r .campaign.endAt "$DATASET") + 5 * 86400 ))
cast rpc evm_setNextBlockTimestamp "$day5" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
result_hash=$($VERIFY "$DATASET" --json | jq -r .resultHash)
cast send "$ESCROW" "settle(uint256,uint256,bytes32,bytes32)" "$(jq -r .campaignId "$DATASET")" \
  "$(jq -r .totals.recognized "$DATASET")" "$(jq -r .merkle.root "$DATASET")" "$result_hash" \
  --private-key "$SETTLER_KEY" --rpc-url "$RPC" >/dev/null

step "Verify against the settled campaign"
$VERIFY "$DATASET" --rpc-url "$RPC"

step "Claim every payout"
node --input-type=module -e "
  import { readFileSync } from 'node:fs';
  import { buildPayoutTree } from './sdk/dist/index.js';
  const d = JSON.parse(readFileSync('$DATASET', 'utf8'));
  const leaves = d.merkle.leaves.map((l) => ({ wallet: l.wallet, amount: BigInt(l.amount) }));
  for (const l of buildPayoutTree(BigInt(d.campaignId), leaves).leaves) {
    console.log(l.wallet, l.amount.toString(), '[' + l.proof.join(',') + ']');
  }
" | while read -r wallet amount proof; do
  cast send "$ESCROW" "claim(uint256,address,uint256,bytes32[])" 1 "$wallet" "$amount" "$proof" \
    --private-key "$SETTLER_KEY" --rpc-url "$RPC" >/dev/null
  balance=$(cast call "$USDC" "balanceOf(address)(uint256)" "$wallet" --rpc-url "$RPC" | cut -d' ' -f1)
  if [ "$balance" != "$amount" ]; then
    echo "FAIL: $wallet received $balance, expected $amount" >&2
    exit 1
  fi
  echo "$wallet received $amount"
done

step "Done: every payout was claimed with an SDK proof"
