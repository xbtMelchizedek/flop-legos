// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {IsolatedMarket} from "../../src/IsolatedMarket.sol";

contract IsolatedMarketFuzzTest is MarketFixture {
    function setUp() public override {
        super.setUp();
        _approveAll(lender);
        _approveAll(borrower);
        usd.mint(lender, 1e30);
        vm.prank(lender);
        market.supply(1e30);
    }

    /// Model: max debt = floor(floor(c * px / 1e36) * lltv / 1e18), computed in two steps by hand.
    /// Borrowing exactly that succeeds on a fresh market; one more unit is refused.
    function testFuzz_lltvBoundaryMatchesModel(uint96 c, uint96 pxWhole) public {
        vm.assume(c > 1e6 && pxWhole > 0);
        uint256 px = uint256(pxWhole) * 1e18;
        _setPrice(px);
        flop.mint(borrower, c);
        vm.prank(borrower);
        market.supplyCollateral(c);
        uint256 value = uint256(c) * px / 1e36;
        uint256 maxDebt = value * LLTV / 1e18;
        if (maxDebt == 0 || maxDebt > 1e30) return;
        vm.prank(borrower);
        vm.expectRevert(IsolatedMarket.Unhealthy.selector);
        market.borrow(maxDebt + 1);
        vm.prank(borrower);
        market.borrow(maxDebt);
        assertEq(market.borrowAssetsOf(borrower), maxDebt);
    }

    /// Rounding direction, checked exactly: borrow shares minted must be worth at least the assets lent out,
    /// i.e. shares * (A + 1) >= assets * (S + 1e6) against the totals just before the borrow.
    function testFuzz_borrowSharesRoundAgainstBorrower(uint64 first, uint32 dt, uint64 second) public {
        vm.assume(first > 0 && second > 0);
        flop.mint(borrower, 1e30);
        vm.prank(borrower);
        market.supplyCollateral(1e30);
        vm.prank(borrower);
        market.borrow(first);
        vm.warp(block.timestamp + dt);
        _setPrice(PX);
        market.accrueInterest();
        uint256 a0 = market.totalBorrowAssets();
        uint256 s0 = market.totalBorrowShares();
        vm.prank(borrower);
        uint256 minted = market.borrow(second);
        assertGe(minted * (a0 + 1), uint256(second) * (s0 + 1e6));
    }

    /// Supplying then withdrawing everything you can never returns more than you put in.
    function testFuzz_supplyWithdrawNeverProfits(uint128 a) public {
        vm.assume(a > 0);
        address l2 = makeAddr("l2");
        _approveAll(l2);
        usd.mint(l2, a);
        vm.prank(l2);
        market.supply(a);
        uint256 back = market.supplyAssetsOf(l2);
        assertLe(back, a);
        if (back == 0) return;
        vm.prank(l2);
        market.withdraw(back);
    }
}
