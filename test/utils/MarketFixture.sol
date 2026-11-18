// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IsolatedMarket} from "../../src/IsolatedMarket.sol";
import {BandedOracle} from "../../src/oracle/BandedOracle.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {MockFLOP} from "../../src/mocks/MockFLOP.sol";

abstract contract MarketFixture is Test {
    MockFLOP internal flop; // collateral
    MockFLOP internal usd; // loan asset stand-in (another mock ERC20)
    MockFeed internal primaryFeed;
    MockFeed internal secondaryFeed;
    BandedOracle internal oracle;
    IsolatedMarket internal market;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    /// 1 collateral unit = 2 loan units, both 18 decimals, scaled 1e36.
    uint256 internal constant PX = 2e36;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LIF = 1.05e18;
    uint256 internal constant RATE = 1e9; // ~3.2% simple per year
    uint256 internal constant BAND_BPS = 200;
    uint256 internal constant MAX_AGE = 1 hours;

    function setUp() public virtual {
        vm.warp(1_000_000);
        flop = new MockFLOP();
        usd = new MockFLOP();
        primaryFeed = new MockFeed();
        secondaryFeed = new MockFeed();
        primaryFeed.set(PX);
        secondaryFeed.set(PX);
        oracle = new BandedOracle(primaryFeed, secondaryFeed, BAND_BPS, MAX_AGE);
        market = new IsolatedMarket(address(usd), address(flop), oracle, LLTV, LIF, RATE);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        usd.approve(address(market), type(uint256).max);
        flop.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function _setPrice(uint256 px) internal {
        primaryFeed.set(px);
        secondaryFeed.set(px);
    }
}
