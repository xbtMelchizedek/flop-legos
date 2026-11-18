# flop-legos

> **Unaudited prototype. Not deployed anywhere. There is no token.** Local Foundry tests against mocks only.
> `MockFLOP` is a test stand-in; FLOP Labs says there is no FLOP token yet, and this repo does not create one.

Money legos for agent compute, sketched as Solidity. Two pieces:

| contract | shape | what it does |
|---|---|---|
| `ComputeVault` | ERC-4626, yVault-style | Agents pool one compute budget. A keeper allocates it to a strategy that reserves escrow with allowlisted miners; a settlement verdict pays the miner for verified work and refunds the rest. |
| `MockComputeStrategy` | mock of a FLOP compute channel | escrow → verdict → miner paid at the channel price (rounded down) → remainder refunded; permissionless refund after timeout; per-epoch spend cap like FLOP's agent-wallet daily cap. |
| `IsolatedMarket` | isolated lending market (shape learned from Morpho Blue, code ours) | One collateral, one loan asset, one oracle, fixed LLTV / incentive / rate, no owner. Bad debt is written off against suppliers. |
| `BandedOracle` | two feeds, one band | Returns the primary price only if a second feed agrees within the band, both are fresh and nonzero. Otherwise reverts. |

**Why Solidity if FLOP has no contracts?** FLOP is a Substrate L1 with no VM by design; its docs tell teams that need contracts to
"build that part on an EVM chain and settle compute on FLOP". These contracts are that EVM part, prototyped. See
[docs/SPEC.md](docs/SPEC.md) §0 and the design doc in our research notes.

## Run

```sh
forge build --sizes
forge test                       # 512 fuzz runs, 256 x 64 invariant
FOUNDRY_PROFILE=ci forge test    # 10k fuzz, 1k x 64 invariant
python3 scripts/mutate.py        # break the code 15 ways; writes docs/MUTATION.md
python3 scripts/secret_scan.py
```

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
- No deploy scripts, no keys, no RPC URLs.

## Credits and licenses

MIT. Vendored: Solady (MIT, `lib/solady`, unmodified) and forge-std (MIT/Apache-2.0). Patterns were learned by reading
Yearn v3, Morpho Blue, Aave v3 and Uniswap v4-core, which are AGPL/GPL/BUSL; no code was copied from them.
Security: see [SECURITY.md](SECURITY.md).
