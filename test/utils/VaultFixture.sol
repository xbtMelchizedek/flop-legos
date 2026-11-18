// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ComputeVault} from "../../src/ComputeVault.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";
import {MockFLOP} from "../../src/mocks/MockFLOP.sol";

abstract contract VaultFixture is Test {
    MockFLOP internal flop;
    MockComputeStrategy internal strategy;
    ComputeVault internal vault;

    address internal governor = makeAddr("governor");
    address internal keeper = makeAddr("keeper");
    address internal settler = makeAddr("settler");
    address internal guardian = makeAddr("guardian");
    address internal miner = makeAddr("miner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal eve = makeAddr("eve");

    uint256 internal constant EPOCH_CAP = 1_000e18;
    /// 1e-6 FLOP per G_n, in PRICE_SCALE units.
    uint256 internal constant MAX_PRICE = 1e12 * 1e18 / 1e18;
    uint256 internal constant CAP = 1e30;

    function setUp() public virtual {
        flop = new MockFLOP();
        strategy = new MockComputeStrategy(address(flop), governor, keeper, settler, EPOCH_CAP, MAX_PRICE);
        vault = new ComputeVault(address(flop), 18, strategy, governor, CAP);
        vm.startPrank(governor);
        strategy.setVault(address(vault));
        strategy.setMiner(miner, true);
        vault.setKeeper(keeper);
        vault.setGuardian(guardian);
        vm.stopPrank();
        vm.warp(1_000_000);
    }

    function _fund(address who, uint256 amount) internal {
        flop.mint(who, amount);
        vm.prank(who);
        flop.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        _fund(who, amount);
        vm.prank(who);
        shares = vault.deposit(amount, who);
    }
}
