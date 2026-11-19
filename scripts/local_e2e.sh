#!/usr/bin/env bash
# Local end-to-end proof: anvil on 127.0.0.1 with Robinhood Chain testnet's chain id and a Cancun EVM, then
# scripts/rhc.sh deploy + smoke with BROADCAST=1, then an independent on-chain check with cast. Never leaves localhost.
# The deployer key is anvil's account 0, taken from anvil's own --config-out into a mode-600 temp file; it never
# touches the repo.
#
#   scripts/local_e2e.sh
set -euo pipefail

readonly CHAIN_ID=46630
readonly PORT="${E2E_PORT:-8546}"
readonly RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
umask 077
tmp="$(mktemp -d)"
anvil_pid=""
other_pid=""
in_repo="$ROOT/deployments/anvil/inrepo.key"
cleanup() {
  for p in "$anvil_pid" "$other_pid"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
  rm -f "$in_repo"
}
trap cleanup EXIT

anvil --host 127.0.0.1 --port "$PORT" --chain-id "$CHAIN_ID" --hardfork cancun \
  --config-out "$tmp/anvil.json" --silent &
anvil_pid=$!
for _ in $(seq 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
[[ "$(cast chain-id --rpc-url "$RPC")" == "$CHAIN_ID" ]] || { echo "anvil did not start" >&2; exit 1; }

jq -r '.private_keys[0]' "$tmp/anvil.json" > "$tmp/deployer.key"
chmod 600 "$tmp/deployer.key"

# Guards: each of these must be refused before forge runs.
expect_refusal() {
  local why="$1" reason; shift
  if reason="$(env "$@" "$ROOT/scripts/rhc.sh" deploy 2>&1 >/dev/null)"; then echo "guard failed: $why" >&2; exit 1; fi
  echo "refused as expected ($why): $reason"
}
cp "$tmp/deployer.key" "$tmp/loose.key" && chmod 644 "$tmp/loose.key"
ln -s "$tmp/deployer.key" "$tmp/link.key"
mkdir -p "$(dirname "$in_repo")" && cp "$tmp/deployer.key" "$in_repo" && chmod 600 "$in_repo"
printf 'not-a-key\n' > "$tmp/garbage.key" && chmod 600 "$tmp/garbage.key"
anvil --host 127.0.0.1 --port "$((PORT + 1))" --silent & other_pid=$!
for _ in $(seq 50); do cast chain-id --rpc-url "http://127.0.0.1:$((PORT + 1))" >/dev/null 2>&1 && break; sleep 0.2; done
expect_refusal "no key file" -u DEPLOYER_KEY_FILE RPC_URL="$RPC"
expect_refusal "mode 644" DEPLOYER_KEY_FILE="$tmp/loose.key" RPC_URL="$RPC"
expect_refusal "symlink" DEPLOYER_KEY_FILE="$tmp/link.key" RPC_URL="$RPC"
expect_refusal "inside repo" DEPLOYER_KEY_FILE="$in_repo" RPC_URL="$RPC"
expect_refusal "malformed key" DEPLOYER_KEY_FILE="$tmp/garbage.key" RPC_URL="$RPC"
expect_refusal "chain 31337" DEPLOYER_KEY_FILE="$tmp/deployer.key" RPC_URL="http://127.0.0.1:$((PORT + 1))"
kill "$other_pid" 2>/dev/null || true
rm -f "$in_repo"

export DEPLOYER_KEY_FILE="$tmp/deployer.key" RPC_URL="$RPC" BROADCAST=1 DEPLOYMENTS_DIR=deployments/anvil
out="$ROOT/deployments/anvil/$CHAIN_ID.json"
rm -f "$out"
"$ROOT/scripts/rhc.sh" deploy
"$ROOT/scripts/rhc.sh" smoke

# Second method: read the chain directly, not the script's simulation.
usdc="$(jq -r .tUSDC "$out")"; vault="$(jq -r .vault "$out")"; miner="$(jq -r .miner "$out")"
deployer="$(jq -r .deployer "$out")"; strategy="$(jq -r .strategy "$out")"
for c in tUSDC tFLOP strategy vault oracle market; do
  [[ "$(cast code --rpc-url "$RPC" "$(jq -r ".$c" "$out")")" != "0x" ]] || { echo "no code at $c" >&2; exit 1; }
done
miner_bal="$(cast call --rpc-url "$RPC" "$usdc" 'balanceOf(address)(uint256)' "$miner" | awk '{print $1}')"
me_bal="$(cast call --rpc-url "$RPC" "$usdc" 'balanceOf(address)(uint256)' "$deployer" | awk '{print $1}')"
vault_assets="$(cast call --rpc-url "$RPC" "$vault" 'totalAssets()(uint256)' | awk '{print $1}')"
shares="$(cast call --rpc-url "$RPC" "$vault" 'balanceOf(address)(uint256)' "$deployer" | awk '{print $1}')"
paid_total="$(cast call --rpc-url "$RPC" "$strategy" 'paidToMiners()(uint256)' | awk '{print $1}')"
symbol="$(cast call --rpc-url "$RPC" "$usdc" 'symbol()(string)')"

[[ "$miner_bal" == "40000000" && "$paid_total" == "40000000" ]] || { echo "miner paid $miner_bal / $paid_total" >&2; exit 1; }
[[ "$shares" == "0" ]] || { echo "shares left: $shares" >&2; exit 1; }
[[ "$((me_bal + miner_bal + vault_assets))" == "1000000000" ]] || { echo "conservation broken" >&2; exit 1; }
printf '{"ok":true,"chainId":%s,"symbol":%s,"minerPaid":%s,"deployerBack":%s,"vaultDust":%s,"deployment":"%s"}\n' \
  "$CHAIN_ID" "$symbol" "$miner_bal" "$me_bal" "$vault_assets" "deployments/anvil/$CHAIN_ID.json"
