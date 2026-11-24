# Deploying the compute vault to HyperEVM testnet

**Status: prepared, not deployed.** The vault mints a share token (`fvFLOP`). Creating any token needs palmer's explicit OK, so nothing has been broadcast. Prepared 2026-11-24 by 0xMelchizedek.

## Chain (from Hyperliquid's official docs, read 2026-11-24 1:40 PM ET)

| | value | source |
|---|---|---|
| Chain ID | **998** (RPC returned `0x3e6`) | https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm |
| JSON-RPC | `https://rpc.hyperliquid-testnet.xyz/evm` | same page |
| Gas token | HYPE, 18 decimals; EIP-1559, base and priority fees burned | same page |
| EVM version | Cancun without blobs (PUSH0 confirmed with an `eth_call` on the live RPC) | same page |
| Block gas | small blocks 3M gas every 1 s; big blocks 30M every 1 min, opt-in through a HyperCore `evmUserModify` action | https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture |
| Wrapped HYPE | canonical `0x5555555555555555555555555555555555555555` (WETH9 clone); live on testnet: `WHYPE`, 18 decimals | https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/wrapped-hype |
| Faucet | 1,000 mock USDC on HyperCore at https://app.hyperliquid-testnet.xyz/drip, **only for addresses that have deposited on mainnet** | https://hyperliquid.gitbook.io/hyperliquid-docs/onboarding/testnet-faucet |
| Core → EVM HYPE | send HYPE to `0x2222222222222222222222222222222222222222` | HyperEVM page, "Native Transfers" |

## What gets deployed (2 contracts, 3 setup calls)

| # | tx | gas limit in the dry run (estimate x1.3) |
|---|---|---|
| 1 | `MockComputeStrategy(asset=WHYPE, governor=keeper=settler=deployer, epochCap=10e18, maxPricePerGn=1e12)` | 1,329,654 |
| 2 | `FlopVault(asset=WHYPE, 18, strategy, owner=deployer, depositCap=100e18)` | 2,298,836 |
| 3 | `strategy.setVault(vault)` (one-shot) | 66,190 |
| 4 | `vault.setKeeper(deployer)` | 65,279 |
| 5 | `vault.setGuardian(deployer)` | 69,161 |
| | **total** | **3,829,120 gas ≈ 0.000766 HYPE** at the dry run's 0.2 gwei max fee (base fee was ~0.108 gwei) |

Each transaction fits a 3M small block, so big blocks are not needed. `StableMath` is an internal library and is not deployed. No new asset token is created: the vault holds the existing canonical WHYPE. No miner is allowlisted, so no compute channel can open until the governor names one.

## The share token (this is what needs approval)

- Name `FlopVault compute vault (prototype)`, symbol **`fvFLOP`**, 24 decimals (asset decimals + 6 virtual-share decimals).
- **Mint:** only by `deposit(assets, receiver)` / `mint(shares, receiver)`, against WHYPE pulled into the vault, at the entry mark (idle + strategy free + reserved), rounded down for the depositor. Capped by `depositCap` (100 WHYPE) and stopped while paused.
- **Burn:** only by `withdraw` / `redeem`, paid at the exit mark (idle + strategy free), rounded in the vault's favor. Withdrawals stay open while paused.
- Standard transferable ERC-20 (Solady). No owner mint, no owner burn, no fee, no emissions, no rebasing.
- Owner powers: set keeper, guardian, deposit cap; unpause. Two-step ownership with 48 h expiry. Guardian can pause, never unpause, never block withdrawals.

## Exact command after approval (one command, run on the box)

The deployer needs ~0.001 testnet HYPE first (see Gas below).

```sh
cd /home/box/agent-data/0xmelchizdek/flop-legos && HYPEREVM_DEPLOYER_KEY=$(python3 -c 'import json;print(json.load(open("/home/box/.secrets/hyperevm-testnet/deployer.json"))["private_key"])') forge script script/DeployHyperEVM.s.sol:DeployHyperEVM --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast --slow
```

The script refuses any chain other than 998 (`WrongChain`) and checks the wiring after deploy (`WiringFailed`). The key only lives in that process's environment; it is never on the command line or in git.

## Dry run (done, no broadcast)

```sh
anvil --port 8546 --fork-url https://rpc.hyperliquid-testnet.xyz/evm --chain-id 998
DEPLOYER_ADDR=0xDd54b8e0CCA47eB79B8e1564fB5CB28BBe23ED85 forge script script/DeployHyperEVM.s.sol:DeployHyperEVM --rpc-url http://127.0.0.1:8546 --gas-estimate-multiplier 130
HYPEREVM_FORK_URL=http://127.0.0.1:8546 forge test --match-path test/fork/HyperEVMFork.t.sol --disable-block-gas-limit
```

Result on 2026-11-24 (fork block 70,499,941): "SIMULATION COMPLETE", 5 transactions, wiring checks passed. Fork tests 4/4: wiring, WHYPE deposit → redeem round trip returns exactly 5 WHYPE, the 100 WHYPE cap holds, other chains refused. (`--disable-block-gas-limit` lifts the 3M limit only for the test harness, which deploys the whole script contract in one frame; the real transactions are listed above and each is under 3M.)

## Deployer

`0xDd54b8e0CCA47eB79B8e1564fB5CB28BBe23ED85`: fresh throwaway key made on the box with `cast wallet new` for this purpose only, stored at `/home/box/.secrets/hyperevm-testnet/` (dir 700, files 600). Testnet only. Never fund it from a trading wallet and never reuse it.

## Gas: how to get testnet HYPE

The official faucet only serves addresses that have **deposited on Hyperliquid mainnet**. The throwaway deployer never will (that would mean real money, which we don't move). So:

1. **palmer** uses his own Hyperliquid account (if it has a mainnet deposit) to claim mock USDC at the drip page, buys a little testnet HYPE on testnet spot, and sends ~0.01 HYPE to the deployer on HyperEVM (Core → EVM via `0x2222…2222`, then an EVM transfer). Only testnet assets move; it's palmer's action, not mine.
2. Third-party testnet faucets exist but are not official; not used, and not checked for sign-up or captcha requirements.

I did not request faucet funds.

## Risks

- **Unaudited prototype.** Tested locally (unit, fuzz, invariant, mutation in `docs/MUTATION.md`) and on a fork; never reviewed by a third party.
- **One key holds every role** (owner, keeper, settler, guardian). Fine for testnet; on any real deploy these must be split and the owner put behind a multisig/timelock.
- **The strategy is a mock.** The settler (us) decides each channel's verdict; there is no proof from FLOP yet. Depositors trust the settler. FLOP has no contracts and no bridge, so the FLOP side is an off-chain operator.
- **The share is a token** and will show up on explorers as `fvFLOP`. It is not FLOP, is not backed by FLOP (it holds WHYPE on testnet), and has no value.
- **Hyperliquid terms:** earlier research flagged that Hyperliquid's interface terms restrict US persons (research/flop_agent_trading_layer.md). Using the public RPC directly isn't the interface, but palmer should decide.
- Withdrawals are guaranteed only from idle + strategy free balance; funds reserved in an open channel return after settlement or timeout.
