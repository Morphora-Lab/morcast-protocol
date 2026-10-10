#!/usr/bin/env bash
# Deploys a test build of MorcastEscrow whose campaign days last DAY_SECONDS seconds instead of
# 86,400, so that a whole campaign runs in about an hour on a test network.
#
# The build is the contract in src with its three timing constants scaled. Settlement opens after
# 5 days and closes after 10, and a campaign lasts at most 90, all counted in days of
# DAY_SECONDS. Everything else is the same code. The script builds it in a temporary copy of the
# project, so src never changes and the genuine contract keeps its code hash. A test build has
# another code hash, so the SDK's isGenuineEscrow answers false for it. It is for test networks
# only, and the script refuses Base mainnet.
#
# Requirements: Foundry. RPC_URL and DAY_SECONDS, and the variables of script/Deploy.s.sol:
# OWNER, SETTLER, TREASURY, USDC and MOR. Options after the script name go to `forge script`,
# such as the signer and --broadcast.
#
# Usage:
#   RPC_URL=https://sepolia.base.org DAY_SECONDS=300 OWNER=0x… SETTLER=0x… TREASURY=0x… \
#   USDC=0x… MOR=0x… scripts/deploy-short-days.sh --keystore <file> --password-file <file> --broadcast

set -euo pipefail

rpc="${RPC_URL:?Set RPC_URL, the test network to deploy to}"
day="${DAY_SECONDS:?Set DAY_SECONDS, the length of a campaign day in seconds}"
if ! [[ "$day" =~ ^[0-9]+$ ]] || ((day < 60 || day >= 86400)); then
  echo "DAY_SECONDS must be a whole number of seconds from 60 to 86399." >&2
  exit 1
fi

chain="$(cast chain-id --rpc-url "$rpc")"
if [[ "$chain" == "8453" ]]; then
  echo "A test build never goes to Base mainnet." >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A copy of the project with the libraries linked, so the build uses the same compiler settings.
cp "$root/foundry.toml" "$root/remappings.txt" "$work/"
cp -r "$root/src" "$root/script" "$work/"
ln -s "$root/lib" "$work/lib"

escrow="$work/src/MorcastEscrow.sol"
sed -i -E \
  -e "s/(SETTLEMENT_OPENS_AFTER = )5 days;/\1$((5 * day));/" \
  -e "s/(SETTLEMENT_CLOSES_AFTER = )10 days;/\1$((10 * day));/" \
  -e "s/(MAX_CAMPAIGN_DURATION = )90 days;/\1$((90 * day));/" \
  "$escrow"
# Each constant must now be a number of seconds. Otherwise the build would keep real days.
for constant in SETTLEMENT_OPENS_AFTER SETTLEMENT_CLOSES_AFTER MAX_CAMPAIGN_DURATION; do
  if ! grep -Eq "$constant = [0-9]+;" "$escrow"; then
    echo "Could not scale $constant in src/MorcastEscrow.sol." >&2
    exit 1
  fi
done

echo "Deploying a test build with days of $day seconds to chain $chain."
cd "$work"
forge script script/Deploy.s.sol --rpc-url "$rpc" "$@"
