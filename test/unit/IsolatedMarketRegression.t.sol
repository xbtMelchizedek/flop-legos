// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {IsolatedMarketHandler} from "../invariant/IsolatedMarketHandler.sol";

/// Regression for the invariant-fuzz finding of 2026-11-24: after zero-floored totalBorrowAssets, a dust
/// liquidation computed repaidShares > the position's borrowShares and reverted with panic 0x11.
/// This replays the shrunk 16-call sequence exactly.
contract IsolatedMarketRegressionTest is MarketFixture {
    function test_regression_liquidate_dust_repaidShares_capped() public {
        IsolatedMarketHandler h = new IsolatedMarketHandler(market, usd, flop, primaryFeed, secondaryFeed);
        h.movePrice(227341071688076301516);
        h.movePrice(7000000000000000000);
        h.movePrice(2000000000000000000000000000000000000);
        h.supplyCollateral(24, 21600);
        h.movePrice(5000000000000000000000000);
        h.supply(9999, 172800);
        h.borrow(
            6200920361113706221308493244876699716544263733072756935314,
            3590114516664976698622193334787517105334478581910957826675
        );
        h.movePrice(360964253533);
        h.movePrice(5000);
        h.movePrice(341126016732968446720853943504812137953);
        h.supplyCollateral(9799, 10);
        h.repay(9, 4220);
        h.borrow(15803379166564585157411163021823, 1122204505373603651526614282);
        h.movePrice(4);
        h.movePrice(3371);
        h.liquidate(401000000000000000000, 922, 160000000000000000001); // panicked before the cap
        assertEq(h.breaches(), 0);
        assertLe(market.totalBorrowAssets(), market.totalSupplyAssets());
    }
}
