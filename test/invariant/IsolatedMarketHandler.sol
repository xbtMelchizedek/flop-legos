// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IsolatedMarket} from "../../src/IsolatedMarket.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {MockFLOP} from "../../src/mocks/MockFLOP.sol";

/// Bounded actions from named actors. The model judges health on its own arithmetic with a 1% margin either side;
/// calls inside the "allowed" margin are made directly (a revert fails the run), calls inside the "forbidden" margin
/// are tried and counted as breaches if accepted.
contract IsolatedMarketHandler is Test {
    IsolatedMarket public market;
    MockFLOP public loan;
    MockFLOP public coll;
    MockFeed public feedA;
    MockFeed public feedB;
    address[3] public actors;
    uint256 public breaches;
    uint256 public liquidations;
    uint256 public borrows;
    uint256 public px = 2e36;

    constructor(IsolatedMarket m, MockFLOP loan_, MockFLOP coll_, MockFeed a, MockFeed b) {
        market = m;
        loan = loan_;
        coll = coll_;
        feedA = a;
        feedB = b;
        actors = [makeAddr("m0"), makeAddr("m1"), makeAddr("m2")];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(actors[i]);
            loan.approve(address(m), type(uint256).max);
            coll.approve(address(m), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % 3];
    }

    function _debt(address a) internal view returns (uint256) {
        return market.borrowAssetsOf(a);
    }

    function _maxDebt(address a) internal view returns (uint256) {
        (,, uint256 c) = market.positions(a);
        return c * (px / 1e18) / 1e18 * market.lltv() / 1e18;
    }

    function supply(uint256 i, uint256 assets) external {
        market.accrueInterest();
        assets = bound(assets, 1, 1e27);
        address a = _actor(i);
        loan.mint(a, assets);
        vm.prank(a);
        market.supply(assets);
    }

    function withdraw(uint256 i, uint256 assets) external {
        market.accrueInterest();
        address a = _actor(i);
        uint256 mine = market.supplyAssetsOf(a);
        uint256 liquid = market.totalSupplyAssets() - market.totalBorrowAssets();
        uint256 cap = mine < liquid ? mine : liquid;
        if (cap <= 1) return;
        assets = bound(assets, 1, cap - 1);
        vm.prank(a);
        market.withdraw(assets);
    }

    function supplyCollateral(uint256 i, uint256 assets) external {
        assets = bound(assets, 1, 1e27);
        address a = _actor(i);
        coll.mint(a, assets);
        vm.prank(a);
        market.supplyCollateral(assets);
    }

    function borrow(uint256 i, uint256 assets) external {
        market.accrueInterest();
        address a = _actor(i);
        uint256 debt = _debt(a);
        uint256 maxD = _maxDebt(a);
        uint256 liquid = market.totalSupplyAssets() - market.totalBorrowAssets();
        uint256 room = maxD * 99 / 100 > debt ? maxD * 99 / 100 - debt : 0;
        if (room > liquid) room = liquid > 0 ? liquid - 1 : 0;
        if (assets % 4 != 0 && room != 0) {
            assets = assets % 4 == 1 ? room : bound(assets, 1, room);
            vm.prank(a);
            market.borrow(assets);
            borrows++;
            return;
        }
        // Over the line by at least 1%: must be refused.
        uint256 over = maxD * 101 / 100 + 1;
        assets = over > debt ? over - debt + bound(assets, 0, 1e24) : bound(assets, 1, 1e24);
        vm.prank(a);
        try market.borrow(assets) {
            breaches++;
        } catch {}
    }

    function withdrawCollateral(uint256 i, uint256 assets) external {
        market.accrueInterest();
        address a = _actor(i);
        (, uint256 bs, uint256 c) = market.positions(a);
        if (c == 0) return;
        assets = bound(assets, 1, c);
        uint256 debt = _debt(a);
        uint256 maxAfter = (c - assets) * (px / 1e18) / 1e18 * market.lltv() / 1e18;
        if (bs == 0 || debt * 100 <= maxAfter * 99) {
            vm.prank(a);
            market.withdrawCollateral(assets);
        } else if (debt * 100 >= maxAfter * 101) {
            vm.prank(a);
            try market.withdrawCollateral(assets) {
                breaches++;
            } catch {}
        }
    }

    function repay(uint256 i, uint256 shares) external {
        market.accrueInterest();
        address a = _actor(i);
        (, uint256 bs,) = market.positions(a);
        if (bs == 0) return;
        shares = bound(shares, 1, bs);
        loan.mint(a, market.borrowAssetsOf(a) + 1);
        vm.prank(a);
        market.repay(shares, a);
    }

    function liquidate(uint256 i, uint256 j, uint256 seized) external {
        market.accrueInterest();
        address liq = _actor(i);
        address b = _actor(j);
        if (liq == b) return;
        (, uint256 bs, uint256 c) = market.positions(b);
        if (bs == 0 || c == 0) return;
        uint256 debt = _debt(b);
        uint256 maxD = _maxDebt(b);
        if (debt * 100 >= maxD * 101) {
            // seize no more than the collateral whose discounted value clears the whole debt, with margin
            uint256 seizeForDebt = debt * market.lif() / 1e18 * 1e18 / (px / 1e18) * 99 / 100;
            uint256 cap = seizeForDebt < c ? seizeForDebt : c;
            if (cap == 0) return;
            seized = bound(seized, 1, cap);
            loan.mint(liq, debt + 1);
            vm.prank(liq);
            market.liquidate(b, seized);
            liquidations++;
        } else if (debt * 100 <= maxD * 99) {
            loan.mint(liq, debt + 1);
            vm.prank(liq);
            try market.liquidate(b, 1) {
                breaches++;
            } catch {}
        }
    }

    /// Moves both feeds together, within the band. Biased down, because drops are what make liquidations reachable.
    function movePrice(uint256 bps) external {
        bps = bound(bps, 8_000, 11_000);
        px = px * bps / 10_000;
        if (px < 1e34) px = 1e34;
        if (px > 1e38) px = 1e38;
        px = px / 1e18 * 1e18;
        feedA.set(px);
        feedB.set(px);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 30 minutes));
        feedA.set(px);
        feedB.set(px);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
