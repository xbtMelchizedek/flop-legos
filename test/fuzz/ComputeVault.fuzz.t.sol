// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "../utils/VaultFixture.sol";

/// Stateless properties, each checked against a second way of computing the expected value.
contract ComputeVaultFuzzTest is VaultFixture {
    function _state(uint256 seed, uint256 allocated, uint256 escrow, uint256 workGn) internal {
        seed = bound(seed, 1, 1e27);
        _deposit(bob, seed);
        allocated = bound(allocated, 0, seed);
        if (allocated != 0) {
            vm.prank(keeper);
            vault.allocate(allocated);
        }
        escrow = bound(escrow, 0, allocated < EPOCH_CAP ? allocated : EPOCH_CAP);
        if (escrow != 0) {
            vm.prank(keeper);
            uint256 id = strategy.openChannel(miner, escrow, MAX_PRICE);
            if (workGn % 2 == 0) {
                vm.prank(settler);
                strategy.settle(id, bound(workGn, 0, 1e30));
            }
        }
    }

    /// Model: shares = floor(a * (S + 1e6) / (A + 1)), computed without the library.
    function testFuzz_previewDepositMatchesModel(uint256 seed, uint256 alloc, uint256 esc, uint256 work, uint256 a)
        public
    {
        _state(seed, alloc, esc, work);
        a = bound(a, 0, 1e30);
        uint256 s = vault.totalSupply() + 1e6;
        uint256 t = vault.totalAssets() + 1;
        assertEq(vault.previewDeposit(a), (a * s) / t);
        assertEq(vault.previewMint(a), (a * t + s - 1) / s);
    }

    function testFuzz_roundTripNeverProfits(uint256 seed, uint256 alloc, uint256 esc, uint256 work, uint256 a) public {
        _state(seed, alloc, esc, work);
        a = bound(a, 1, 1e29);
        if (vault.previewDeposit(a) == 0) return;
        uint256 shares = _deposit(alice, a);
        uint256 max = vault.maxRedeem(alice);
        if (vault.previewRedeem(max) == 0) return;
        vm.prank(alice);
        uint256 out = vault.redeem(max, alice, alice);
        assertLe(out, a);
        assertLe(max, shares);
    }

    function testFuzz_mintThenWithdrawNeverProfits(uint256 seed, uint256 alloc, uint256 esc, uint256 work, uint256 sh)
        public
    {
        _state(seed, alloc, esc, work);
        sh = bound(sh, 1e6, 1e36);
        uint256 cost = vault.previewMint(sh);
        if (cost > vault.maxDeposit(alice)) return;
        _fund(alice, cost);
        vm.prank(alice);
        vault.mint(sh, alice);
        uint256 w = vault.maxWithdraw(alice);
        if (w == 0) return;
        vm.prank(alice);
        uint256 burned = vault.withdraw(w, alice, alice);
        assertLe(w, cost);
        assertLe(burned, sh);
    }

    function testFuzz_previewMintCoversPreviewDeposit(uint256 seed, uint256 alloc, uint256 esc, uint256 work, uint256 a)
        public
    {
        _state(seed, alloc, esc, work);
        a = bound(a, 0, 1e30);
        assertLe(vault.previewMint(vault.previewDeposit(a)), a);
    }
}
