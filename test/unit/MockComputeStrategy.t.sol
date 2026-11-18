// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "../utils/VaultFixture.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";

contract MockComputeStrategyTest is VaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 2_000e18);
        vm.prank(keeper);
        vault.allocate(2_000e18);
    }

    function _open(uint256 escrow) internal returns (uint256 id) {
        vm.prank(keeper);
        id = strategy.openChannel(miner, escrow, MAX_PRICE);
    }

    function test_settlePaysWorkAtPriceRoundedDown() public {
        uint256 id = _open(10e18);
        // 3 G_n at 1e12 per G_n plus a fractional price: pick a price that does not divide evenly.
        vm.prank(keeper);
        uint256 id2 = strategy.openChannel(miner, 10e18, 3);
        vm.prank(settler);
        strategy.settle(id2, 1); // 1 * 3 / 1e18 = 0.000...3 -> 0
        assertEq(flop.balanceOf(miner), 0);
        vm.prank(settler);
        strategy.settle(id, 4e6);
        assertEq(flop.balanceOf(miner), 4e6 * MAX_PRICE / 1e18);
        assertEq(strategy.paidToMiners(), 4e6 * MAX_PRICE / 1e18);
    }

    function test_settleCapsPaymentAtEscrow() public {
        uint256 id = _open(1e18);
        vm.prank(settler);
        strategy.settle(id, type(uint128).max);
        assertEq(flop.balanceOf(miner), 1e18);
        assertEq(strategy.reserved(), 0);
    }

    function test_channelSettlesOnce() public {
        uint256 id = _open(1e18);
        vm.prank(settler);
        strategy.settle(id, 1);
        vm.expectRevert(MockComputeStrategy.ChannelNotOpen.selector);
        vm.prank(settler);
        strategy.settle(id, 1);
        vm.warp(block.timestamp + 5 hours);
        vm.expectRevert(MockComputeStrategy.ChannelNotOpen.selector);
        strategy.refundTimedOut(id);
    }

    function test_refundOnlyAfterDeadlineAndSettleOnlyBefore() public {
        uint256 id = _open(1e18);
        vm.expectRevert(MockComputeStrategy.TooEarly.selector);
        strategy.refundTimedOut(id);
        vm.warp(block.timestamp + strategy.CHANNEL_TTL() + 1);
        vm.expectRevert(MockComputeStrategy.TooLate.selector);
        vm.prank(settler);
        strategy.settle(id, 1);
        vm.prank(eve); // permissionless keeper job
        strategy.refundTimedOut(id);
        assertEq(strategy.free(), 2_000e18);
    }

    function test_epochCapCountsReservationsAndResets() public {
        _open(600e18);
        vm.expectRevert(MockComputeStrategy.EpochCapExceeded.selector);
        vm.prank(keeper);
        strategy.openChannel(miner, 401e18, MAX_PRICE);
        _open(400e18);
        vm.warp(block.timestamp + strategy.EPOCH());
        _open(500e18);
        assertEq(strategy.spentThisEpoch(), 500e18);
    }

    function test_unlistedMinerAndHighPriceRefused() public {
        vm.expectRevert(MockComputeStrategy.MinerNotAllowed.selector);
        vm.prank(keeper);
        strategy.openChannel(eve, 1e18, MAX_PRICE);
        vm.expectRevert(MockComputeStrategy.PriceAboveCap.selector);
        vm.prank(keeper);
        strategy.openChannel(miner, 1e18, MAX_PRICE + 1);
    }

    function test_onlySettlerSettles() public {
        uint256 id = _open(1e18);
        vm.expectRevert(MockComputeStrategy.NotSettler.selector);
        vm.prank(miner);
        strategy.settle(id, 1e30);
    }
}
