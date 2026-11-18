# flop-legos v0 spec

Unaudited prototype. Not deployed. No token. All facts about FLOP below were read on 18 Nov 2026 from
docs.flop.network (llms-full.txt, "devnet / next") and flop-labs/yellowpaper 0.5.0 (draft, commit a5b4326d006c).

## 0. Where this runs

FLOP is a Substrate L1, "non-EVM, not Turing-complete", with "no smart contracts and no general-purpose VM, by design";
"a team that needs general-purpose smart contracts should build that part on an EVM chain and settle compute on FLOP"
(docs: technology-and-chain). FLOP "will not build bridges" but third parties may connect it. So these contracts are
the EVM half. The FLOP half is an agent wallet (spend caps, allowlist, circuit breaker; yellowpaper §6.2) that an
off-chain operator drives, and the strategy mock stands in for it.

## 1. ComputeVault

### 1.1 Roles
- **owner** (two-step, 48 h expiry): sets keeper, guardian, deposit cap; unpauses.
- **guardian**: pauses deposits and allocation. Cannot unpause. Cannot block withdrawals.
- **keeper**: moves assets between vault idle and strategy free balance.
- **strategy** (immutable): one per vault. Its vault address is set once.

### 1.2 Accounting
- `idle` is internal; tokens sent to the vault do not count. The strategy's `free` and `reserved` are internal too.
- `totalAssets = idle + strategy.free + strategy.reserved` (entry mark).
- `exitAssets = idle + strategy.free` (exit mark).
- Share math: `shares = assets * (supply + 1e6) / (assets_mark + 1)`, with 18 + 6 share decimals.

| function | mark | rounding |
|---|---|---|
| previewDeposit | entry | down |
| previewMint | entry | up |
| previewWithdraw | exit | up |
| previewRedeem | exit | down |

### 1.3 Why two marks
A compute vault has no yield. It has consumption: escrow reserved with a miner may be paid out at settlement.
If exits used the full mark, a holder could leave just before a settlement and push the cost onto everyone else.
So escrow counts at full value for entries and at zero for exits, and a round trip can never profit.

The cost: a holder who leaves while escrow is reserved gives up their share of that escrow to whoever stays,
even if it is later refunded. Channels last at most `CHANNEL_TTL` (4 h in the mock), so the fix for a holder is to
wait. A v1 could replace this with Yearn-style locked profit (treat reservations as spent, release refunds over
time) or an exit queue. Owner's call; tested in `test_exitDuringReservationForfeitsEscrowShareToStayers`.

### 1.4 Strategy (mock)
- `openChannel(miner, escrow, pricePerGn)`, keeper-only: miner on the allowlist, price at or under `maxPricePerGn`,
  escrow at or under free balance, and under `epochCap` per 86,400 s window. The window resets on the first spend after
  it ends, which mirrors R6.2b's 86,400-block rule. The cap counts reservations, not payments.
- `settle(id, workGn)`, settler-only (stands in for the FLOP settlement verdict) before the deadline:
  `paid = min(floor(workGn * price / 1e18), escrow)`, and the rest returns to free.
- `refundTimedOut(id)`: anyone after the deadline. This is a keeper job.

## 2. IsolatedMarket

- Immutable: loan token, collateral token, oracle, `lltv`, `lif`, `ratePerSecond`. No owner and no upgrades.
  Constructor requires `lif ≥ 1`, `lltv * lif < 1`, and distinct tokens with code.
- Health: `ceil(debt) ≤ floor(floor(collateral * price / 1e36) * lltv)`.
- Supply shares round down on supply and up on withdraw. Borrow shares round up on borrow; repay is by shares and
  owes assets rounded up. Interest is simple, accrued before every money path, and rounded down.
- Liquidation (unhealthy only): the liquidator names `seized` collateral and pays `ceil(seized * price / 1e36 / lif)`.
  Debt shares cleared round down. If the borrower is left with zero collateral and nonzero debt, the rest is written off
  from both total borrow and total supply.
- Oracle reads happen only on borrow, collateral exit with debt, and liquidation. Supply, withdraw, repay and
  debt-free collateral exit never read a price.

## 3. BandedOracle

Each feed returns `(price, updatedAt)`. The read reverts on zero (`OracleZero`), on age over `maxAge` or a future
timestamp (`OracleStale`), and when `|p - s| * 10_000 > s * bandBps` (`OracleBand`). There is no fallback and no last
good price. Fail-closed also blocks liquidations during an outage. That trade-off is deliberate for v0 and listed in
the design doc.
