# FlopVault (flop-legos)

> **Unaudited prototype. Not deployed anywhere. There is no token.** Local Foundry tests and a local anvil run only.
> `MockFLOP` and `tFLOP-TEST` are test stand-ins; FLOP Labs says there is no FLOP token yet, and this repo does not
> create one. A Robinhood Chain *testnet* deploy script exists; nobody has run it against the real testnet.

FlopVault: money legos for agent compute, sketched as Solidity.

| contract | shape | what it does |
|---|---|---|
| `FlopVault` | ERC-4626, yVault-style | Agents pool one compute budget. A keeper allocates it to a strategy that reserves escrow with allowlisted miners; a settlement verdict pays the miner for verified work and refunds the rest. |
| `MockComputeStrategy` | mock of a FLOP compute channel | escrow → verdict → miner paid at the channel price (rounded down) → remainder refunded; permissionless refund after timeout; per-epoch spend cap like FLOP's agent-wallet daily cap. |
| `IsolatedMarket` | isolated lending market (shape learned from Morpho Blue, code ours) | One collateral, one loan asset, one oracle, fixed LLTV / incentive / rate, no owner. Bad debt is written off against suppliers. |
| `BandedOracle` | two feeds, one band | Returns the primary price only if a second feed agrees within the band, both are fresh and nonzero. Otherwise reverts. |
| `TestToken` | testnet mock ERC-20 | `tUSDC-TEST` / `tFLOP-TEST`. No value, anyone mints (capped per call), and not tradable: every transfer must start or end at an allowlisted protocol contract. |

**Why Solidity if FLOP has no contracts?** FLOP is a Substrate L1 with no VM by design; its docs tell teams that need contracts to
"build that part on an EVM chain and settle compute on FLOP". These contracts are that EVM part, prototyped. See
[docs/SPEC.md](docs/SPEC.md) §0 and the design doc in our research notes.

## Run

```sh
forge build --sizes
forge test                       # 512 fuzz runs, 256 x 64 invariant
FOUNDRY_PROFILE=ci forge test    # 10k fuzz, 1k x 64 invariant
python3 scripts/mutate.py        # break the code 21 ways; writes docs/MUTATION.md
python3 scripts/secret_scan.py
scripts/local_e2e.sh             # deploy + smoke on local anvil with chain id 46630
```

## Deploying to Robinhood Chain testnet

> **Unaudited. Mocks only. No real FLOP, no real USDC. Testnet only.** The scripts refuse any chain id except
> 46630 (Robinhood Chain testnet), mainnet 4663 included. A live deploy waits for palmer's approval; see REPORT.md.
> Chain facts and their sources: [docs/ROBINHOOD_CHAIN.md](docs/ROBINHOOD_CHAIN.md).

What gets deployed: `tUSDC-TEST` (6 decimals), `tFLOP-TEST` (18 decimals), `MockComputeStrategy`, `FlopVault`
(asset tUSDC-TEST), two `MockFeed`s, `BandedOracle` and `IsolatedMarket` (lend tUSDC-TEST against tFLOP-TEST).
All parameters in `script/DeployFlopVault.s.sol` are arbitrary test values, including the 1 tFLOP = 1 tUSDC test peg.
They are not prices.

1. **Prove it locally first.** This needs no key and no network:
   ```sh
   scripts/local_e2e.sh
   ```
   It starts anvil on 127.0.0.1 with chain id 46630 and a Cancun EVM, checks that six bad inputs are refused,
   deploys, runs the smoke round trip, and re-checks balances on chain with `cast`. Output goes to
   `deployments/anvil/` (gitignored).
2. **Make a throwaway deployer key** that holds nothing else. Keep it outside this repo, mode 600:
   ```sh
   umask 077; mkdir -p ~/.flopvault
   # Piped, cast prints "address<TAB>key" on stdout and a human copy (with the key) on stderr, so drop stderr.
   cast wallet new 2>/dev/null | awk -F'\t' '{ print $2 > "'"$HOME"'/.flopvault/rhc-testnet.key"; print "deployer:", $1 }'
   chmod 600 ~/.flopvault/rhc-testnet.key
   ```
3. **Fund the address with testnet ETH** from the faucet Robinhood names
   (`faucet.testnet.chain.robinhood.com`). We could not confirm its login or captcha requirements; see the docs file.
4. **Dry run.** This simulates against the public testnet RPC and broadcasts nothing:
   ```sh
   DEPLOYER_KEY_FILE=~/.flopvault/rhc-testnet.key scripts/rhc.sh deploy
   ```
5. **Broadcast (only with palmer's OK):**
   ```sh
   DEPLOYER_KEY_FILE=~/.flopvault/rhc-testnet.key BROADCAST=1 scripts/rhc.sh deploy
   DEPLOYER_KEY_FILE=~/.flopvault/rhc-testnet.key BROADCAST=1 scripts/rhc.sh smoke
   ```
   Addresses go to `deployments/46630.json`. A second deploy refuses to overwrite that file.
6. Look the contracts up on `https://explorer.testnet.chain.robinhood.com`.

Caveats:

- `scripts/rhc.sh` refuses to run unless the key file exists, is not a symlink, is mode 600, is owned by you,
  lives outside the repo and holds one 0x-hex key. It also refuses an RPC whose chain id is not 46630.
  The key reaches forge only through the child process's environment, never on a command line.
  Set `RPC_URL` to use a provider; forge saves that URL in `cache/` (gitignored).
- The deployer holds every role: owner, governor, keeper, settler and guardian. That is fine for a mock testnet
  and wrong for anything else.
- Anyone can set the mock feeds and mint test tokens. The market and vault prove wiring, not economics.
- Vault shares (`FLOPV`) are ordinary ERC-20s; only the mock assets are transfer-restricted.
- Cancun support is inferred from Arbitrum's ArbOS docs; Robinhood publishes no hardfork list.
- Robinhood's Terms of Service cover the testnet: no VPN to get around geographic limits, and no "automated
  tools (such as bots, scrapers, or spiders)". Read them before running keepers or CI against the public RPC.
- Robinhood says its public RPC is rate-limited and not for production.

## Design rules this follows

- Virtual shares and assets on every share conversion (no empty-pool inflation); donations never count (internal accounting).
- Every division rounds in the protocol's favor, named at the call site.
- A transient reentrancy lock on every value-moving entry, on top of checks-effects-interactions.
- Fee-on-transfer tokens are refused, not half-supported; tokens without code are refused.
- Prices come from two feeds within a band or not at all. Lenders and debt-free borrowers can still leave while the oracle fails closed.
- Two-step ownership with a 48-hour expiry. The guardian can pause deposits but never unpause, and never blocks withdrawals.

Invariants, fuzz properties and the mutation table: [docs/TESTING.md](docs/TESTING.md), [docs/MUTATION.md](docs/MUTATION.md).

## Not in this repo (on purpose)

- No ve(3,3), gauges, emissions or token. Those are design notes only and need a decision from the owner.
- No mainnet deploy path, no keys, no real FLOP or USDC. The only RPC is Robinhood Chain's public *testnet* endpoint.

## Credits and licenses

MIT. Vendored: Solady (MIT, `lib/solady`, unmodified) and forge-std (MIT/Apache-2.0). Patterns were learned by reading
Yearn v3, Morpho Blue, Aave v3 and Uniswap v4-core, which are AGPL/GPL/BUSL; no code was copied from them.
Security: see [SECURITY.md](SECURITY.md).
