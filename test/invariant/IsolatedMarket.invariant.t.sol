// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {IsolatedMarketHandler} from "./IsolatedMarketHandler.sol";

/// Invariants, in words:
/// 1. Loan tokens held >= supplied - borrowed (never less; rounding dust may only add).
/// 2. Borrowed never exceeds supplied.
/// 3. Collateral tokens held == sum of positions' collateral, exactly.
/// 4. Supply and borrow shares are conserved across actors.
/// 5. The market never accepted a borrow, collateral exit or liquidation the model forbids (breaches == 0).
contract IsolatedMarketInvariantTest is MarketFixture {
    IsolatedMarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new IsolatedMarketHandler(market, usd, flop, primaryFeed, secondaryFeed);
        targetContract(address(handler));
    }

    function invariant_loanTokensBackNetSupply() public view {
        assertGe(usd.balanceOf(address(market)), market.totalSupplyAssets() - market.totalBorrowAssets());
    }

    function invariant_borrowedNeverExceedsSupplied() public view {
        assertLe(market.totalBorrowAssets(), market.totalSupplyAssets());
    }

    function invariant_collateralExact() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            (,, uint256 c) = market.positions(handler.actorAt(i));
            sum += c;
        }
        assertEq(flop.balanceOf(address(market)), sum);
    }

    function invariant_sharesConserved() public view {
        uint256 s;
        uint256 b;
        for (uint256 i; i < 3; i++) {
            (uint256 ss, uint256 bs,) = market.positions(handler.actorAt(i));
            s += ss;
            b += bs;
        }
        assertEq(s, market.totalSupplyShares());
        assertEq(b, market.totalBorrowShares());
    }

    function invariant_noBreaches() public view {
        assertEq(handler.breaches(), 0);
    }
}
