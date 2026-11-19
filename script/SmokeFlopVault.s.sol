// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited. TESTNET ONLY. One round trip on a deployed stack: deposit, allocate, pay the mock miner for verified
/// work, pull back, redeem everything. Reverts unless every balance moves exactly as the model says.

import {FlopVaultDeployment} from "./FlopVaultDeployment.sol";
import {FlopVault} from "../src/FlopVault.sol";
import {MockComputeStrategy} from "../src/mocks/MockComputeStrategy.sol";
import {TestToken} from "../src/mocks/TestToken.sol";

contract SmokeFlopVault is FlopVaultDeployment {
    error SmokeMismatch(string what, uint256 got, uint256 want);

    // Arbitrary test amounts in tUSDC-TEST base units (6 decimals).
    uint256 public constant DEPOSIT = 1_000e6;
    uint256 public constant ALLOCATE = 500e6;
    uint256 public constant ESCROW = 100e6;
    uint256 public constant PRICE_PER_GN = 1e18;
    uint256 public constant WORK_GN = 40e6;
    /// WORK_GN * PRICE_PER_GN / PRICE_SCALE, rounded down.
    uint256 public constant EXPECTED_PAID = 40e6;

    struct Result {
        uint256 shares;
        uint256 channelId;
        uint256 paidToMiner;
        uint256 redeemed;
    }

    function run() external returns (Result memory r) {
        r = smoke(_deployerKey(), _read());
    }

    function smoke(uint256 pk, Deployment memory d) public returns (Result memory r) {
        _requireTestnet();
        address me = vm.addr(pk);
        TestToken usdc = TestToken(d.tUSDC);
        FlopVault vault = FlopVault(d.vault);
        MockComputeStrategy strategy = MockComputeStrategy(d.strategy);

        uint256 minerBefore = usdc.balanceOf(d.miner);
        uint256 vaultBefore = vault.totalAssets();
        uint256 meBefore = usdc.balanceOf(me);

        vm.startBroadcast(pk);
        usdc.mint(me, DEPOSIT);
        usdc.approve(address(vault), DEPOSIT);
        r.shares = vault.deposit(DEPOSIT, me);
        vault.allocate(ALLOCATE);
        r.channelId = strategy.openChannel(d.miner, ESCROW, PRICE_PER_GN);
        strategy.settle(r.channelId, WORK_GN);
        vault.deallocate(strategy.freeAssets());
        r.redeemed = vault.redeem(r.shares, me, me);
        vm.stopBroadcast();

        r.paidToMiner = usdc.balanceOf(d.miner) - minerBefore;
        _check("miner paid", r.paidToMiner, EXPECTED_PAID);
        // Conservation: what was minted is now with me, the miner, or still in the vault (rounding dust only).
        uint256 vaultKept = vault.totalAssets() - vaultBefore;
        _check("conservation", (usdc.balanceOf(me) - meBefore) + r.paidToMiner + vaultKept, DEPOSIT);
        _check("redeemed", usdc.balanceOf(me) - meBefore, r.redeemed);
        if (r.redeemed > DEPOSIT - EXPECTED_PAID) {
            revert SmokeMismatch("redeem above net", r.redeemed, DEPOSIT - EXPECTED_PAID);
        }
    }

    function _check(string memory what, uint256 got, uint256 want) internal pure {
        if (got != want) revert SmokeMismatch(what, got, want);
    }
}
