// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "../utils/VaultFixture.sol";
import {FlopVaultHandler} from "./FlopVaultHandler.sol";

/// Invariants, in words:
/// 1. totalAssets == deposits - withdrawals - miner payouts (exact).
/// 2. Tokens held by vault + strategy == totalAssets + donations (donations never count).
/// 3. Strategy reserved == sum of open escrows in the model; free + reserved == strategy.totalAssets.
/// 4. Sum of actor shares == totalSupply.
/// 5. Actors together never take out more than they put in (there is no yield source, only consumption).
///    Per actor this can fail by design: exiting while escrow is reserved forfeits that share to remaining holders.
/// 6. Epoch spend never exceeds the cap; payouts equal the strategy's counter.
/// 7. The contract never accepted a call the model forbids (breaches == 0).
contract FlopVaultInvariantTest is VaultFixture {
    FlopVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FlopVaultHandler(vault, strategy, flop, keeper, settler, miner);
        targetContract(address(handler));
    }

    function invariant_totalAssetsMatchesLedger() public view {
        assertEq(vault.totalAssets(), handler.ghostDeposited() - handler.ghostWithdrawn() - handler.ghostPaid());
    }

    function invariant_tokensBackAssetsDonationsIgnored() public view {
        assertEq(
            flop.balanceOf(address(vault)) + flop.balanceOf(address(strategy)),
            vault.totalAssets() + handler.ghostDonated()
        );
    }

    function invariant_reservedMatchesOpenEscrow() public view {
        assertEq(strategy.reserved(), handler.ghostReserved());
        assertEq(strategy.free() + strategy.reserved(), strategy.totalAssets());
    }

    function invariant_sharesConserved() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            sum += vault.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, vault.totalSupply());
    }

    function invariant_actorsTogetherNeverProfit() public view {
        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i; i < 3; i++) {
            address a = handler.actorAt(i);
            totalIn += handler.ghostIn(a);
            totalOut += handler.ghostOut(a);
        }
        assertLe(totalOut, totalIn);
    }

    function invariant_capsAndPayouts() public view {
        assertLe(strategy.spentThisEpoch(), strategy.epochCap());
        assertEq(strategy.paidToMiners(), handler.ghostPaid());
    }

    function invariant_noBreaches() public view {
        assertEq(handler.breaches(), 0);
    }
}
