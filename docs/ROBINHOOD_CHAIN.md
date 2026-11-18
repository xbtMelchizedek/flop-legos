# Robinhood Chain testnet: verified facts

Checked 18 November 2026, from official Robinhood sources only (docs.robinhood.com, robinhood.com, cdn.robinhood.com,
the official explorer). Where an answer needs Arbitrum's docs, it is labelled **Arbitrum docs (not Robinhood)**.
Anything not found in an official source is **UNKNOWN**. Page text is quoted as data.

| fact | value | source |
|---|---|---|
| Testnet chain ID | **46630** (hex 0xb626, our conversion) | [connecting](https://docs.robinhood.com/chain/connecting): "Chain ID 4663 46630" (mainnet, testnet columns); [testnet chain-info JSON](https://cdn.robinhood.com/assets/generated_assets/hoodchain_docsite/chain-node-configs/robinhood-chain-testnet-info.json): `"chain-id": 46630`, `"chain-name": "Robinhood Chain Sepolia"` |
| Official public RPC (testnet) | `https://rpc.testnet.chain.robinhood.com` (HTTP). No public testnet WebSocket RPC listed | [connecting](https://docs.robinhood.com/chain/connecting): "The following public endpoints are available but are rate-limited and not recommended for production use." |
| Rate limit numbers | **UNKNOWN** (none published) | [terms](https://docs.robinhood.com/chain/terms-of-service): public RPC "is subject to rate limits" and may be throttled or discontinued "without notice" |
| Explorer (testnet) | `https://explorer.testnet.chain.robinhood.com` (Blockscout; verification API at `/api/`) | [connecting](https://docs.robinhood.com/chain/connecting); [deploy-smart-contracts](https://docs.robinhood.com/chain/deploy-smart-contracts) |
| Faucet URL | `faucet.testnet.chain.robinhood.com` | [Help Center](https://robinhood.com/us/en/support/articles/robinhood-chain-mainnet/): "You can get testnet tokens at faucet.testnet.chain.robinhood.com." |
| Faucet gating (login? captcha? amount?) | **UNKNOWN**. The faucet page returned HTTP 429 plus a Vercel bot checkpoint to our non-browser fetch. That is a bot wall, not proof of a captcha. Third-party sites give amounts; not cited | none official |
| Stack | Arbitrum Nitro, Rollup (not AnyTrust); parent chain **Ethereum Sepolia (11155111)**; gas token ETH | [connecting](https://docs.robinhood.com/chain/connecting): "an Arbitrum Layer-2 Chain built on Ethereum, using Ethereum blobs for data availability and ETH as the native gas token"; chain-info JSON: `"parent-chain-id": 11155111`, `"DataAvailabilityCommittee": false` (Rollup is our reading of that flag) |
| EVM compatibility claim | "fully EVM-compatible": Robinhood says *compatible*, never *equivalent* | [docs home](https://docs.robinhood.com/chain): "Smart contracts written in Solidity or Vyper deploy without modification" |
| Supported hardfork / PUSH0 / Cancun | **UNKNOWN from Robinhood**: no hardfork or opcode list is published. ArbOS: "Robinhood Chain runs ArbOS 61" ([run-a-full-node](https://docs.robinhood.com/chain/run-a-full-node); the page does not say whether this covers testnet); testnet genesis `"InitialArbOSVersion": 51` (chain-info JSON) | **Arbitrum docs (not Robinhood)**: [ArbOS 11](https://docs.arbitrum.io/run-arbitrum-node/arbos-releases/arbos11) adds Shanghai incl. PUSH0; [ArbOS 20](https://docs.arbitrum.io/run-arbitrum-node/arbos-releases/arbos20) adds TSTORE/TLOAD and MCOPY (Cancun); [ArbOS 40](https://docs.arbitrum.io/run-arbitrum-node/arbos-releases/arbos40) adds Pectra. Our inference: ArbOS ≥ 51 runs Cancun bytecode |
| Listed differences from Ethereum | `block.number` is an L1 estimate; prevrandao is constant; `blockhash` only for recent blocks; two-part fees (L2 gas + L1 data); max code size 96 KB; FCFS ordering; sequencer drops transactions tied to sanctioned addresses | [differences-from-ethereum](https://docs.robinhood.com/chain/differences-from-ethereum) |
| Mainnet live? | **Yes**, chain ID 4663. Launch date **UNKNOWN** | [docs home](https://docs.robinhood.com/chain): "Robinhood Chain is live."; [Help Center](https://robinhood.com/us/en/support/articles/robinhood-chain-mainnet/): "Chain ID: 4663" |
| Who may deploy | Permissionless; no deployer allowlist or KYC is mentioned | [docs home](https://docs.robinhood.com/chain): "Anyone can interact with the network, build applications, and deploy smart contracts." |
| Builder terms | Terms of Service (RHDA, LLC; updated August 24, 2026) explicitly cover the testnet: use "only to test and improve ... Robinhood Chain or applications built on it"; testnet tokens "have no monetary value"; 18+, not a Prohibited Person, no VPN or proxy to get around geographic limits; prohibits "use of automated tools (such as bots, scrapers, or spiders)"; mandatory arbitration | [terms-of-service](https://docs.robinhood.com/chain/terms-of-service) |
| Official test USDC on testnet | **UNKNOWN**. None listed; we deploy our own valueless `tUSDC-TEST` | [protocol-contracts](https://docs.robinhood.com/chain/protocol-contracts) lists only bridge, WETH, Multicall and Permit2 for testnet |
| Official GitHub | No chain repo found under [github.com/robinhood](https://github.com/robinhood). Nodes run Offchain Labs' `nitro-node` | [notices-and-upgrades](https://docs.robinhood.com/chain/notices-and-upgrades) |

## What this means for FlopVault

- `evm_version = "cancun"` in `foundry.toml`. Our contracts need TSTORE/TLOAD (Solady's transient reentrancy guard),
  PUSH0 and MCOPY. Cancun on ArbOS ≥ 20 is an inference from Arbitrum's docs; Robinhood does not state it.
  Do one read-only bytecode check on testnet before relying on it (see REPORT open questions).
- Our contracts read `block.timestamp` only, never `block.number`, `prevrandao` or `blockhash`, so the listed
  differences do not change their logic. Gas estimates differ because of the L1 data fee.
- The ToS ban on "automated tools" bears on keeper bots, CI against the public RPC, and scripted faucet use.
  This needs palmer's reading before any automated testnet keeper runs.
