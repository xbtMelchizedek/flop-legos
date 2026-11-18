"""Break the contracts on purpose, one mutant at a time, and record which tests catch each one.

    python3 scripts/mutate.py            # writes docs/MUTATION.md
"""
import pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MUTANTS = [
    ("M1", "vault: previewDeposit rounds up", "src/FlopVault.sol",
     "    function previewDeposit(uint256 assets) public view returns (uint256) {\n        return assets.fullMulDiv(",
     "    function previewDeposit(uint256 assets) public view returns (uint256) {\n        return assets.fullMulDivUp("),
    ("M2", "vault: virtual shares 1e6 -> 1", "src/FlopVault.sol",
     "VIRTUAL_SHARES = 1e6;", "VIRTUAL_SHARES = 1;"),
    ("M3", "vault: drop nonReentrant on deposit", "src/FlopVault.sol",
     "function deposit(uint256 assets, address receiver) external nonReentrant",
     "function deposit(uint256 assets, address receiver) external"),
    ("M4", "vault: exits priced at full mark (incl. reserved escrow)", "src/FlopVault.sol",
     "        return idle + strategy.freeAssets();\n    }\n\n    /// Rounds down. Informational",
     "        return idle + strategy.totalAssets();\n    }\n\n    /// Rounds down. Informational"),
    ("M5", "vault: accept fee-on-transfer shortfall", "src/FlopVault.sol",
     "        if (SafeTransferLib.balanceOf(asset, address(this)) - before != assets) revert FeeOnTransferRefused();\n        idle += assets;\n    }\n\n    function _pullFromStrategy",
     "        idle += assets;\n    }\n\n    function _pullFromStrategy"),
    ("M6", "strategy: miner payment not capped at escrow", "src/mocks/MockComputeStrategy.sol",
     "uint256 paid = FixedPointMathLib.min(workGn.fullMulDiv(c.pricePerGn, PRICE_SCALE), c.escrow);",
     "uint256 paid = workGn.fullMulDiv(c.pricePerGn, PRICE_SCALE); if (paid > c.escrow + free) paid = c.escrow + free;"),
    ("M7", "strategy: epoch spend not recorded", "src/mocks/MockComputeStrategy.sol",
     "        spentThisEpoch += escrow;\n", ""),
    ("M8", "strategy: refund before deadline allowed", "src/mocks/MockComputeStrategy.sol",
     "        if (block.timestamp <= c.deadline) revert TooEarly();\n", ""),
    ("M9", "market: health check 1% lenient", "src/IsolatedMarket.sol",
     "return debt <= maxDebt;", "return debt <= maxDebt + maxDebt / 100;"),
    ("M10", "oracle: band check removed", "src/oracle/BandedOracle.sol",
     "if (diff * MAX_BPS > r * bandBps) revert OracleBand();", ""),
    ("M11", "oracle: staleness check removed", "src/oracle/BandedOracle.sol",
     "if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert OracleStale();", ""),
    ("M12", "market: lender withdraw ignores borrowed liquidity", "src/IsolatedMarket.sol",
     "        totalSupplyAssets -= assets;\n        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();",
     "        totalSupplyAssets -= assets;"),
    ("M13", "market: healthy positions liquidatable", "src/IsolatedMarket.sol",
     "if (_isHealthy(p, px)) revert Healthy();", ""),
    ("M14", "market: bad debt not written off against suppliers", "src/IsolatedMarket.sol",
     "            totalSupplyAssets -= badDebt;\n", ""),
    ("M15", "market: borrow shares round down (borrower favored)", "src/IsolatedMarket.sol",
     "shares = _toSharesUp(assets, totalBorrowAssets, totalBorrowShares);",
     "shares = _toSharesDown(assets, totalBorrowAssets, totalBorrowShares);"),
    ("M16", "test token: wallet-to-wallet transfers allowed", "src/mocks/TestToken.sol",
     "if (from != address(0) && !isEndpoint[from] && !isEndpoint[to]) revert NotTradable();", ""),
    ("M17", "test token: only the sender side counts as endpoint", "src/mocks/TestToken.sol",
     "&& !isEndpoint[from] && !isEndpoint[to])", "&& !isEndpoint[from])"),
    ("M18", "test token: mint cap off by one", "src/mocks/TestToken.sol",
     "if (amount > mintCapPerCall) revert", "if (amount > mintCapPerCall + 1) revert"),
    ("M19", "deploy: chain guard removed", "script/FlopVaultDeployment.sol",
     "if (block.chainid != RHC_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);", ""),
    ("M20", "deploy: tUSDC never allowlists the strategy", "script/DeployFlopVault.s.sol",
     "        usdc.setEndpoint(address(strategy), true);\n", ""),
    ("M21", "smoke: miner payment check removed", "script/SmokeFlopVault.s.sol",
     '_check("miner paid", r.paidToMiner, EXPECTED_PAID);', ""),
]

def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

def main() -> int:
    rows = []
    for mid, what, path, old, new in MUTANTS:
        f = ROOT / path
        src = f.read_text()
        if src.count(old) != 1:
            print(f"{mid}: anchor not found exactly once", file=sys.stderr)
            return 2
        backup = src
        f.write_text(src.replace(old, new))
        try:
            r = run(["forge", "test"])
            out = r.stdout + r.stderr
            failed = sorted({m.group(1) for line in out.splitlines() if line.startswith("[FAIL")
                             for m in [re.search(r"\s((?:test|invariant)\w*)(?:\(|$)", line)] if m})
            compiled = "Compiler run failed" not in out
        finally:
            f.write_text(backup)
        caught = r.returncode != 0 and compiled and failed
        rows.append((mid, what, "caught" if caught else ("no-compile" if not compiled else "SURVIVED"), failed))
        print(mid, rows[-1][2], failed[:4])
    lines = ["# Mutation check", "", "Generated by `python3 scripts/mutate.py` (default profile: 512 fuzz runs, 256x64 invariant).", "",
             "| id | mutant | result | caught by |", "|---|---|---|---|"]
    for mid, what, res, failed in rows:
        lines.append(f"| {mid} | {what} | {res} | {', '.join(failed[:4])}{' …' if len(failed) > 4 else ''} |")
    (ROOT / "docs" / "MUTATION.md").write_text("\n".join(lines) + "\n")
    return 0 if all(r[2] == "caught" for r in rows) else 1

if __name__ == "__main__":
    sys.exit(main())
