# Testing

`forge test` runs unit, fuzz and invariant suites. `FOUNDRY_PROFILE=ci` runs 10,000 fuzz runs and 1,000 x 64 invariant
calls with `fail_on_revert = true`. Handlers never revert. A model-allowed call is made directly, so any revert fails
the run. A model-forbidden call is tried, and if it is accepted it counts as a breach.

## Invariants (plain words)

FlopVault (`test/invariant/FlopVault.invariant.t.sol`):
1. totalAssets equals deposits minus withdrawals minus miner payouts, exactly.
2. Tokens held by the vault and strategy equal totalAssets plus donations. Donations never count.
3. Strategy reserved equals the sum of open escrows in the model, and free plus reserved equals strategy totalAssets.
4. Actor shares sum to totalSupply.
5. Actors together never take out more than they put in.
6. Epoch spend stays at or under the cap, and miner payouts equal the strategy counter.
7. No breaches: no over-cap channel, double settle, early refund or over-max redeem was ever accepted.

IsolatedMarket (`test/invariant/IsolatedMarket.invariant.t.sol`):
1. Loan tokens held are at least supplied minus borrowed.
2. Borrowed never exceeds supplied.
3. Collateral held equals the sum of position collateral, exactly.
4. Supply and borrow shares are conserved across actors.
5. No breaches: no borrow more than 1% over LLTV, no unhealthy collateral exit and no liquidation of a position
   more than 1% healthy was ever accepted.

Coverage note: in one local default-depth run, 18 of 257 invariant runs reached at least one liquidation (20 in total)
and 486 borrows succeeded. Liquidation and bad debt also have direct unit tests.

## Fuzz properties (each with a second method)
- previewDeposit and previewMint equal a hand-written floor/ceil model.
- Deposit then redeem, and mint then withdraw, never return more than went in, from random vault states
  (allocated, reserved, settled).
- previewMint(previewDeposit(a)) ≤ a.
- Oracle band: `|p-s|·1e4 ≤ s·band` is checked against the interval form `s(1-b) ≤ p ≤ s(1+b)`.
- LLTV boundary: borrowing exactly the hand-computed max succeeds and one more unit is refused.
- Borrow shares minted satisfy `shares·(A+1) ≥ assets·(S+1e6)`, so rounding goes against the borrower.
- Supply then withdraw never profits.

- TestToken: a transfer succeeds iff one side is an allowlisted endpoint (fuzzed over both flags).

## Deploy and smoke (Robinhood Chain testnet scripts)
`test/script/DeployFlopVault.t.sol` runs the same `deploy` and `smoke` code the scripts run, in-process:
- Refuses chain ids 4663 (Robinhood mainnet) and 31337; accepts only 46630.
- Every contract is wired as intended (asset, strategy, vault, roles, oracle, endpoints, decimals, test peg).
- Deployed mocks cannot move wallet-to-wallet.
- Smoke round trip: miner paid exactly 40 tUSDC-TEST; minted = redeemed + paid + vault remainder; no shares left.
  A second round on the same deployment pays exactly once more.
- Adversarial: a miner wired to the depositor trips the miner-payment check first.

`scripts/local_e2e.sh` repeats this against a real anvil node (chain id 46630, Cancun) through `scripts/rhc.sh`,
checks six guard refusals (no key file, mode 644, symlink, key inside repo, malformed key, wrong chain id), and
re-reads balances on chain with `cast`, a second method independent of the script's own simulation.

## Mutation check
See [MUTATION.md](MUTATION.md): 21 deliberate bugs, one property or test catching each.
