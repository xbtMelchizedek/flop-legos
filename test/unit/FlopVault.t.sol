// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "../utils/VaultFixture.sol";
import {FlopVault} from "../../src/FlopVault.sol";
import {Owned2Step} from "../../src/Owned2Step.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";
import {IComputeStrategy} from "../../src/interfaces/IComputeStrategy.sol";
import {FeeOnTransferToken, ReentrantToken} from "../utils/Mocks.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

contract FlopVaultTest is VaultFixture {
    // ---- golden vectors ----

    function test_firstDepositMintsVirtualOffsetShares() public {
        uint256 shares = _deposit(alice, 1e18);
        // 1e18 * (0 + 1e6) / (0 + 1)
        assertEq(shares, 1e24);
        assertEq(vault.totalAssets(), 1e18);
        assertEq(vault.decimals(), 24);
    }

    function test_previewRoundingGoldenVector() public {
        _deposit(alice, 3);
        // supply = 3e6, assets = 3. Deposit 1 -> 1 * (3e6 + 1e6) / (3 + 1) = 1e6 exactly.
        assertEq(vault.previewDeposit(1), 1e6);
        // Mint 1 share -> ceil(1 * 4 / 4e6) = 1 asset, not 0.
        assertEq(vault.previewMint(1), 1);
        // Withdraw 1 asset -> ceil(1 * 4e6 / 4) = 1e6 shares; redeem 1e6 - 1 shares -> floor((1e6-1)*4/4e6) = 0.
        assertEq(vault.previewWithdraw(1), 1e6);
        assertEq(vault.previewRedeem(1e6 - 1), 0);
    }

    function test_depositThenRedeemReturnsAtMostDeposit() public {
        _deposit(bob, 7e18 + 3);
        uint256 shares = _deposit(alice, 1e18 + 1);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, 1e18 + 1);
    }

    // ---- adversarial: first depositor / donation ----

    function test_donationDoesNotMoveSharePrice() public {
        _deposit(eve, 1);
        flop.mint(address(vault), 1e24);
        flop.mint(address(strategy), 1e24);
        assertEq(vault.totalAssets(), 1);
        uint256 victimShares = _deposit(alice, 1e18);
        assertGt(victimShares, 0);
        vm.prank(alice);
        uint256 out = vault.redeem(victimShares, alice, alice);
        assertEq(out, 1e18);
    }

    function test_attackerCannotProfitFromTinyFirstDeposit() public {
        uint256 eveShares = _deposit(eve, 1);
        _deposit(alice, 1e18);
        vm.prank(eve);
        uint256 out = vault.redeem(eveShares, eve, eve);
        assertLe(out, 1);
    }

    // ---- adversarial: tokens ----

    function test_feeOnTransferTokenRefused() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        MockComputeStrategy s = new MockComputeStrategy(address(fee), governor, keeper, settler, EPOCH_CAP, MAX_PRICE);
        FlopVault v = new FlopVault(address(fee), 18, s, governor, CAP);
        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(v), type(uint256).max);
        vm.expectRevert(FlopVault.FeeOnTransferRefused.selector);
        v.deposit(100e18, alice);
        vm.stopPrank();
    }

    function test_noCodeAssetRefused() public {
        vm.expectRevert(FlopVault.NoCode.selector);
        new FlopVault(makeAddr("eoa"), 18, strategy, governor, CAP);
    }

    function test_reentrantTokenCannotReenterDeposit() public {
        ReentrantToken hook = new ReentrantToken();
        MockComputeStrategy s = new MockComputeStrategy(address(hook), governor, keeper, settler, EPOCH_CAP, MAX_PRICE);
        FlopVault v = new FlopVault(address(hook), 18, s, governor, CAP);
        hook.mint(alice, 10e18);
        vm.prank(alice);
        hook.approve(address(v), type(uint256).max);
        hook.arm(address(v), abi.encodeCall(FlopVault.deposit, (1e18, alice)));
        vm.prank(alice);
        uint256 shares = v.deposit(1e18, alice);
        assertFalse(hook.reentryOk());
        assertEq(hook.reentryError(), ReentrancyGuardTransient.Reentrancy.selector);
        assertEq(v.totalSupply(), shares);
        assertEq(v.totalAssets(), 1e18);
    }

    // ---- exit mark ----

    function test_exitBeforeSettlementCannotDodgeConsumption() public {
        uint256 aShares = _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        vm.prank(keeper);
        vault.allocate(200e18);
        vm.prank(keeper);
        uint256 id = strategy.openChannel(miner, 100e18, MAX_PRICE);
        // Alice leaves while 100 is in escrow: she is priced on the 100 liquid, i.e. at most 50.
        uint256 maxShares = vault.maxRedeem(alice);
        assertEq(maxShares, aShares);
        vm.prank(alice);
        uint256 out = vault.redeem(aShares, alice, alice);
        assertLe(out, 50e18);
        // Full consumption: the miner is paid the whole escrow.
        vm.prank(settler);
        strategy.settle(id, 100e18 * 1e18 / MAX_PRICE);
        assertEq(flop.balanceOf(miner), 100e18);
        // Bob is left with exactly the rest; nobody received more than they put in minus their half of the spend.
        assertEq(vault.totalAssets(), 200e18 - 100e18 - out);
        assertLe(out + vault.totalAssets(), 100e18);
    }

    function test_entryAtFullMarkExitAtLiquidMarkNeverProfits() public {
        _deposit(bob, 100e18);
        vm.prank(keeper);
        vault.allocate(100e18);
        vm.prank(keeper);
        uint256 id = strategy.openChannel(miner, 60e18, MAX_PRICE);
        uint256 shares = _deposit(alice, 10e18);
        vm.prank(keeper);
        vm.warp(block.timestamp + strategy.CHANNEL_TTL() + 1);
        strategy.refundTimedOut(id);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, 10e18);
    }

    /// Documented trade-off (docs/SPEC.md §1.3): leaving while escrow is reserved forfeits that share to whoever stays.
    function test_exitDuringReservationForfeitsEscrowShareToStayers() public {
        uint256 aShares = _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        vm.prank(keeper);
        vault.allocate(200e18);
        vm.prank(keeper);
        uint256 id = strategy.openChannel(miner, 100e18, MAX_PRICE);
        vm.prank(alice);
        uint256 out = vault.redeem(aShares, alice, alice);
        vm.warp(block.timestamp + strategy.CHANNEL_TTL() + 1);
        strategy.refundTimedOut(id);
        assertApproxEqAbs(out, 50e18, 1);
        assertApproxEqAbs(vault.totalAssets(), 150e18, 1);
    }

    // ---- roles ----

    function test_onlyKeeperAllocates() public {
        _deposit(alice, 10e18);
        vm.expectRevert(FlopVault.NotKeeper.selector);
        vm.prank(eve);
        vault.allocate(1e18);
    }

    function test_guardianPausesButCannotUnpause() public {
        vm.prank(guardian);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        vm.prank(guardian);
        vault.unpause();
    }

    function test_withdrawalsStayOpenWhilePaused() public {
        uint256 shares = _deposit(alice, 10e18);
        vm.prank(guardian);
        vault.pause();
        _fund(bob, 1e18);
        vm.expectRevert(FlopVault.ExceedsMaxDeposit.selector);
        vm.prank(bob);
        vault.deposit(1e18, bob);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 10e18);
    }

    function test_redeemPullsFromStrategyFreeBalance() public {
        uint256 shares = _deposit(alice, 10e18);
        vm.prank(keeper);
        vault.allocate(8e18);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 10e18);
        assertEq(strategy.free(), 0);
    }

    function test_thirdPartyRedeemNeedsAllowance() public {
        uint256 shares = _deposit(alice, 10e18);
        vm.expectRevert();
        vm.prank(eve);
        vault.redeem(shares, eve, alice);
    }

    function test_depositCapEnforced() public {
        vm.prank(governor);
        vault.setDepositCap(5e18);
        _fund(alice, 6e18);
        vm.expectRevert(FlopVault.ExceedsMaxDeposit.selector);
        vm.prank(alice);
        vault.deposit(6e18, alice);
    }

    function test_ownershipHandoverTwoStepWithExpiry() public {
        vm.prank(governor);
        vault.startOwnershipHandover(alice);
        assertEq(vault.owner(), governor);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.expectRevert(Owned2Step.HandoverExpired.selector);
        vm.prank(alice);
        vault.acceptOwnership();
        vm.prank(governor);
        vault.startOwnershipHandover(alice);
        vm.expectRevert(Owned2Step.NotPendingOwner.selector);
        vm.prank(eve);
        vault.acceptOwnership();
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    function test_strategyVaultIsOneShot() public {
        vm.expectRevert(MockComputeStrategy.VaultAlreadySet.selector);
        vm.prank(governor);
        strategy.setVault(eve);
    }

    function test_strategyRejectsNonVault() public {
        vm.expectRevert(MockComputeStrategy.NotVault.selector);
        vm.prank(eve);
        IComputeStrategy(address(strategy)).withdraw(0);
    }
}
