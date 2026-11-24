// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ComputeVault} from "../../src/ComputeVault.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";
import {MockFLOP} from "../../src/mocks/MockFLOP.sol";

/// Drives bounded calls from named actors, keeps an independent model, never reverts itself.
/// breaches = the contract accepted what the model forbids; any revert on a model-allowed call fails the run.
contract ComputeVaultHandler is Test {
    ComputeVault public vault;
    MockComputeStrategy public strategy;
    MockFLOP public flop;
    address public keeper;
    address public settler;
    address public miner;

    address[3] public actors;
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostPaid;
    uint256 public ghostDonated;
    uint256 public ghostReserved;
    uint256 public breaches;
    uint256[] public openIds;
    mapping(uint256 => uint256) public escrowOf;

    constructor(ComputeVault v, MockComputeStrategy s, MockFLOP f, address k, address st, address m) {
        vault = v;
        strategy = s;
        flop = f;
        keeper = k;
        settler = st;
        miner = m;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
        for (uint256 i; i < 3; i++) {
            vm.prank(actors[i]);
            flop.approve(address(vault), type(uint256).max);
        }
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % 3];
    }

    function deposit(uint256 i, uint256 assets) external {
        address a = _actor(i);
        assets = bound(assets, 0, 1e27);
        if (assets > vault.maxDeposit(a) || vault.previewDeposit(assets) == 0) return;
        flop.mint(a, assets);
        vm.prank(a);
        vault.deposit(assets, a);
        ghostIn[a] += assets;
        ghostDeposited += assets;
    }

    function mint(uint256 i, uint256 shares) external {
        address a = _actor(i);
        shares = bound(shares, 0, 1e33);
        uint256 cost = vault.previewMint(shares);
        if (cost == 0 || cost > vault.maxDeposit(a)) return;
        flop.mint(a, cost);
        vm.prank(a);
        uint256 paid = vault.mint(shares, a);
        ghostIn[a] += paid;
        ghostDeposited += paid;
    }

    function redeem(uint256 i, uint256 shares) external {
        address a = _actor(i);
        shares = bound(shares, 0, vault.maxRedeem(a));
        if (vault.previewRedeem(shares) == 0) return;
        vm.prank(a);
        uint256 out = vault.redeem(shares, a, a);
        ghostOut[a] += out;
        ghostWithdrawn += out;
    }

    function withdraw(uint256 i, uint256 assets) external {
        address a = _actor(i);
        assets = bound(assets, 0, vault.maxWithdraw(a));
        if (assets == 0 || vault.previewWithdraw(assets) > vault.balanceOf(a)) return;
        vm.prank(a);
        vault.withdraw(assets, a, a);
        ghostOut[a] += assets;
        ghostWithdrawn += assets;
    }

    function redeemTooMuch(uint256 i) external {
        address a = _actor(i);
        uint256 over = vault.maxRedeem(a) + 1;
        vm.prank(a);
        try vault.redeem(over, a, a) {
            breaches++;
        } catch {}
    }

    function allocate(uint256 assets) external {
        assets = bound(assets, 0, vault.idle());
        if (assets == 0) return;
        vm.prank(keeper);
        vault.allocate(assets);
    }

    function deallocate(uint256 assets) external {
        assets = bound(assets, 0, strategy.free());
        if (assets == 0) return;
        vm.prank(keeper);
        vault.deallocate(assets);
    }

    function openChannel(uint256 escrow, uint256 price) external {
        if (block.timestamp >= strategy.epochStart() + strategy.EPOCH()) {
            // the model knows the window resets on the next spend
        } else if (strategy.spentThisEpoch() >= strategy.epochCap()) {
            return;
        }
        uint256 room = block.timestamp >= strategy.epochStart() + strategy.EPOCH()
            ? strategy.epochCap()
            : strategy.epochCap() - strategy.spentThisEpoch();
        uint256 cap = strategy.free() < room ? strategy.free() : room;
        escrow = bound(escrow, 0, cap);
        if (escrow == 0) return;
        price = bound(price, 0, strategy.maxPricePerGn());
        vm.prank(keeper);
        uint256 id = strategy.openChannel(miner, escrow, price);
        openIds.push(id);
        escrowOf[id] = escrow;
        ghostReserved += escrow;
    }

    function openOverCap() external {
        uint256 cap = strategy.epochCap();
        if (strategy.free() <= cap) return;
        vm.prank(keeper);
        try strategy.openChannel(miner, cap + 1, 0) {
            breaches++;
        } catch {}
    }

    function settle(uint256 k, uint256 workGn) external {
        if (openIds.length == 0) return;
        uint256 idx = k % openIds.length;
        uint256 id = openIds[idx];
        (, uint96 deadline,,,) = strategy.channels(id);
        if (block.timestamp > deadline) return;
        workGn = bound(workGn, 0, 1e30);
        uint256 before = flop.balanceOf(miner);
        vm.prank(settler);
        strategy.settle(id, workGn);
        uint256 paid = flop.balanceOf(miner) - before;
        if (paid > escrowOf[id]) breaches++;
        ghostPaid += paid;
        ghostReserved -= escrowOf[id];
        _drop(idx);
        vm.prank(settler);
        try strategy.settle(id, 0) {
            breaches++;
        } catch {}
    }

    function refund(uint256 k) external {
        if (openIds.length == 0) return;
        uint256 idx = k % openIds.length;
        uint256 id = openIds[idx];
        (, uint96 deadline,,,) = strategy.channels(id);
        if (block.timestamp <= deadline) {
            try strategy.refundTimedOut(id) {
                breaches++;
            } catch {}
            return;
        }
        strategy.refundTimedOut(id);
        ghostReserved -= escrowOf[id];
        _drop(idx);
    }

    function donate(uint256 amount, bool toStrategy) external {
        amount = bound(amount, 0, 1e27);
        flop.mint(toStrategy ? address(strategy) : address(vault), amount);
        ghostDonated += amount;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 6 hours));
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _drop(uint256 idx) internal {
        openIds[idx] = openIds[openIds.length - 1];
        openIds.pop();
    }
}
