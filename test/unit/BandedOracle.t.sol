// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {BandedOracle} from "../../src/oracle/BandedOracle.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";

contract BandedOracleTest is MarketFixture {
    function test_inBandReturnsPrimary() public {
        secondaryFeed.set(PX * 10_200 / 10_000);
        assertEq(oracle.price(), PX);
    }

    function test_justOutsideBandRefused() public {
        secondaryFeed.set(PX * 10_000 / 9_799);
        vm.expectRevert(BandedOracle.OracleBand.selector);
        oracle.price();
    }

    function test_zeroRefused() public {
        primaryFeed.set(0);
        vm.expectRevert(BandedOracle.OracleZero.selector);
        oracle.price();
    }

    function test_staleRefused() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        secondaryFeed.set(PX);
        vm.expectRevert(BandedOracle.OracleStale.selector);
        oracle.price();
    }

    function test_futureTimestampRefused() public {
        primaryFeed.setWithTime(PX, block.timestamp + 1);
        vm.expectRevert(BandedOracle.OracleStale.selector);
        oracle.price();
    }

    function test_sameFeedTwiceRefused() public {
        vm.expectRevert(BandedOracle.BadConfig.selector);
        new BandedOracle(primaryFeed, primaryFeed, BAND_BPS, MAX_AGE);
    }

    /// Second method: the band as an interval [r(1-b), r(1+b)], not as |p-r| <= r*b.
    function testFuzz_bandMatchesIntervalModel(uint128 p, uint128 r) public {
        vm.assume(p != 0 && r != 0);
        primaryFeed.set(p);
        secondaryFeed.set(r);
        bool inBand = uint256(p) * 10_000 <= uint256(r) * (10_000 + BAND_BPS)
            && uint256(p) * 10_000 >= uint256(r) * (10_000 - BAND_BPS);
        if (inBand) {
            assertEq(oracle.price(), p);
        } else {
            vm.expectRevert(BandedOracle.OracleBand.selector);
            oracle.price();
        }
    }
}
