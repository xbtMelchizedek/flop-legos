// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {IsolatedMarket} from "../../src/IsolatedMarket.sol";
import {BandedOracle} from "../../src/oracle/BandedOracle.sol";
import {FeeOnTransferToken} from "../utils/Mocks.sol";

contract IsolatedMarketTest is MarketFixture {
    function setUp() public override {
        super.setUp();
        _approveAll(lender);
        _approveAll(borrower);
        _approveAll(liquidator);
        usd.mint(lender, 1_000e18);
        vm.prank(lender);
        market.supply(1_000e18);
        flop.mint(borrower, 100e18);
        vm.prank(borrower);
        market.supplyCollateral(100e18);
    }

    // golden: 100 collateral * 2 * 0.8 = 160 max debt
    function test_borrowUpToLltvExactly() public {
        vm.prank(borrower);
        market.borrow(160e18);
        assertTrue(market.isHealthy(borrower));
        assertEq(usd.balanceOf(borrower), 160e18);
    }

    function test_borrowOverLltvRefused() public {
        vm.expectRevert(IsolatedMarket.Unhealthy.selector);
        vm.prank(borrower);
        market.borrow(160e18 + 1);
    }

    function test_firstSupplyGoldenShares() public {
        IsolatedMarket m = new IsolatedMarket(address(usd), address(flop), oracle, LLTV, LIF, RATE);
        usd.mint(address(this), 1e18);
        usd.approve(address(m), 1e18);
        assertEq(m.supply(1e18), 1e24);
    }

    function test_oracleOutOfBandFreezesBorrowAndCollateralExit() public {
        vm.prank(borrower);
        market.borrow(10e18);
        secondaryFeed.set(PX * 2);
        vm.expectRevert(BandedOracle.OracleBand.selector);
        vm.prank(borrower);
        market.borrow(1e18);
        vm.expectRevert(BandedOracle.OracleBand.selector);
        vm.prank(borrower);
        market.withdrawCollateral(1e18);
    }

    function test_lendersExitWithoutOracle() public {
        primaryFeed.set(0);
        vm.prank(lender);
        market.withdraw(10e18);
        assertEq(usd.balanceOf(lender), 10e18);
    }

    function test_withdrawCannotTakeBorrowedLiquidity() public {
        vm.prank(borrower);
        market.borrow(160e18);
        vm.expectRevert(IsolatedMarket.InsufficientLiquidity.selector);
        vm.prank(lender);
        market.withdraw(900e18);
    }

    function test_healthyPositionCannotBeLiquidated() public {
        vm.prank(borrower);
        market.borrow(100e18);
        usd.mint(liquidator, 100e18);
        vm.expectRevert(IsolatedMarket.Healthy.selector);
        vm.prank(liquidator);
        market.liquidate(borrower, 1e18);
    }

    function test_liquidationAfterPriceDropPaysIncentive() public {
        vm.prank(borrower);
        market.borrow(160e18);
        _setPrice(1.9e36);
        usd.mint(liquidator, 1_000e18);
        vm.prank(liquidator);
        uint256 repaid = market.liquidate(borrower, 10e18);
        // 10 * 1.9 / 1.05, rounded up
        assertEq(repaid, (uint256(19e18) * 1e18 + 1.05e18 - 1) / 1.05e18);
        assertEq(flop.balanceOf(liquidator), 10e18);
    }

    function test_fullLiquidationWritesOffBadDebtAgainstSuppliers() public {
        vm.prank(borrower);
        market.borrow(160e18);
        _setPrice(1e36); // collateral now worth 100 against 160 debt
        usd.mint(liquidator, 1_000e18);
        vm.prank(liquidator);
        uint256 repaid = market.liquidate(borrower, 100e18);
        (, uint256 bShares, uint256 coll) = market.positions(borrower);
        assertEq(coll, 0);
        assertEq(bShares, 0);
        assertEq(market.totalBorrowAssets(), 0);
        // Suppliers absorb the loss: 1000 - (160 - repaid), up to rounding.
        assertApproxEqAbs(market.totalSupplyAssets(), 1_000e18 - (160e18 - repaid), 2);
        assertGe(usd.balanceOf(address(market)), market.totalSupplyAssets() - market.totalBorrowAssets());
    }

    function test_fullRepayBySharesLeavesNoDebt() public {
        vm.prank(borrower);
        market.borrow(50e18);
        vm.warp(block.timestamp + 30 days);
        usd.mint(borrower, 10e18);
        (, uint256 bShares,) = market.positions(borrower);
        vm.prank(borrower);
        market.repay(bShares, borrower);
        assertEq(market.borrowAssetsOf(borrower), 0);
        vm.prank(borrower);
        market.withdrawCollateral(100e18);
    }

    function test_debtFreeCollateralExitsWithoutOracle() public {
        primaryFeed.set(0);
        vm.prank(borrower);
        market.withdrawCollateral(100e18);
        assertEq(flop.balanceOf(borrower), 100e18);
    }

    function test_interestAccruesToSuppliersRoundedDown() public {
        vm.prank(borrower);
        market.borrow(100e18);
        vm.warp(block.timestamp + 1000);
        market.accrueInterest();
        // 100e18 * 1e9 * 1000 / 1e18 = 1e14
        assertEq(market.totalBorrowAssets(), 100e18 + 1e14);
        assertEq(market.totalSupplyAssets(), 1_000e18 + 1e14);
    }

    function test_badConfigRefused() public {
        vm.expectRevert(IsolatedMarket.BadConfig.selector);
        new IsolatedMarket(address(usd), address(flop), oracle, 0.96e18, 1.05e18, RATE);
        vm.expectRevert(IsolatedMarket.BadConfig.selector);
        new IsolatedMarket(address(usd), address(usd), oracle, LLTV, LIF, RATE);
    }

    function test_feeOnTransferCollateralRefused() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        IsolatedMarket m = new IsolatedMarket(address(usd), address(fee), oracle, LLTV, LIF, RATE);
        fee.mint(borrower, 10e18);
        vm.startPrank(borrower);
        fee.approve(address(m), type(uint256).max);
        vm.expectRevert(IsolatedMarket.FeeOnTransferRefused.selector);
        m.supplyCollateral(10e18);
        vm.stopPrank();
    }
}
