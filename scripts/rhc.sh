#!/usr/bin/env bash
# FlopVault on Robinhood Chain testnet. Unaudited; TEST mocks only.
#
#   DEPLOYER_KEY_FILE=/abs/path/key scripts/rhc.sh deploy            # simulate only
#   DEPLOYER_KEY_FILE=/abs/path/key BROADCAST=1 scripts/rhc.sh deploy
#   DEPLOYER_KEY_FILE=/abs/path/key BROADCAST=1 scripts/rhc.sh smoke
#
# Env: DEPLOYER_KEY_FILE (required; mode 600, owned by you, outside this repo, one 0x-hex key line)
#      RPC_URL (default: the official public testnet RPC), BROADCAST=1 to send, DEPLOYMENTS_DIR (default deployments)
# Refuses any RPC whose chain id is not 46630. The key travels to forge only through the child's environment.
set -euo pipefail

readonly RHC_TESTNET_CHAIN_ID=46630
readonly DEFAULT_RPC_URL="https://rpc.testnet.chain.robinhood.com"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() { printf '{"ok":false,"reason":"%s"}\n' "$1" >&2; exit 1; }

verb="${1:-}"
case "$verb" in
  deploy) target="script/DeployFlopVault.s.sol:DeployFlopVault" ;;
  smoke) target="script/SmokeFlopVault.s.sol:SmokeFlopVault" ;;
  *) fail "usage: rhc.sh deploy|smoke" ;;
esac

key_file="${DEPLOYER_KEY_FILE:-}"
[[ -n "$key_file" ]] || fail "DEPLOYER_KEY_FILE is not set"
[[ ! -L "$key_file" ]] || fail "key file is a symlink"
[[ -f "$key_file" ]] || fail "key file missing or not a regular file"
[[ "$(stat -c %a "$key_file")" == "600" ]] || fail "key file mode must be 600"
[[ "$(stat -c %u "$key_file")" == "$(id -u)" ]] || fail "key file must be owned by the current user"
key_real="$(realpath "$key_file")"
case "$key_real/" in "$ROOT"/*) fail "key file must live outside the repo" ;; esac

key="$(head -n 1 "$key_file" | tr -d '[:space:]')"
[[ "$key" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "key file must hold one 0x-prefixed 32-byte hex key"

rpc="${RPC_URL:-$DEFAULT_RPC_URL}"
chain_id="$(cast chain-id --rpc-url "$rpc" 2>/dev/null)" || fail "cannot read chain id from RPC"
[[ "$chain_id" == "$RHC_TESTNET_CHAIN_ID" ]] || fail "RPC chain id $chain_id is not Robinhood Chain testnet ($RHC_TESTNET_CHAIN_ID)"

args=(script "$target" --rpc-url "$rpc")
if [[ "${BROADCAST:-}" == "1" ]]; then args+=(--broadcast --slow); fi

cd "$ROOT"
DEPLOYER_KEY="$key" DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR:-deployments}" forge "${args[@]}"
