// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableMath} from "../../src/math/StableMath.sol";

/// Thin external wrapper so reverts can be asserted with vm.expectRevert.
contract StableMathHarness {
    function getD(uint256[] memory xp, uint256 a) external pure returns (uint256) {
        return StableMath.getD(xp, a);
    }

    function quoteSwap(uint256[] memory xp, uint256 a, uint256 i, uint256 j, uint256 dx, uint256 fee)
        external
        pure
        returns (uint256)
    {
        return StableMath.quoteSwap(xp, a, i, j, dx, fee);
    }
}

contract StableMathTest is Test {
    StableMathHarness h = new StableMathHarness();

    /// Differential: values from scripts/stable_ref.py (bisection on the exact invariant, 80-digit Decimal).
    /// Tolerance: 2 wei or 1e-15 relative, whichever is larger (Newton stops within 1 wei; integer steps add a little).
    function _near(uint256 got, uint256 want) internal pure {
        uint256 tol = want / 1e15;
        if (tol < 2) tol = 2;
        uint256 diff = got > want ? got - want : want - got;
        require(diff <= tol, "outside reference tolerance");
    }

    function test_reference_0() public pure {
        uint256[] memory xp = new uint256[](2);
        xp[0] = 1000 ether; xp[1] = 1000 ether;
        _near(StableMath.getD(xp, 100), 1999999999999999999999);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 100), 950012465556559855034);
    }
    function test_reference_1() public pure {
        uint256[] memory xp = new uint256[](2);
        xp[0] = 1000 ether; xp[1] = 500 ether;
        _near(StableMath.getD(xp, 100), 1499534015561310279719);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 100), 450242900767788588301);
    }
    function test_reference_2() public pure {
        uint256[] memory xp = new uint256[](2);
        xp[0] = 10 ether; xp[1] = 9000 ether;
        _near(StableMath.getD(xp, 50), 6016006369569715992148);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 50), 6611971422269471124080);
    }
    function test_reference_3() public pure {
        uint256[] memory xp = new uint256[](3);
        xp[0] = 1000 ether; xp[1] = 1000 ether; xp[2] = 1000 ether;
        _near(StableMath.getD(xp, 200), 2999999999999999999999);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 200), 950001391554000813450);
    }
    function test_reference_4() public pure {
        uint256[] memory xp = new uint256[](3);
        xp[0] = 3000 ether; xp[1] = 1000 ether; xp[2] = 20 ether;
        _near(StableMath.getD(xp, 10), 3634519616094643196805);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 10), 959866772441841738636);
    }
    function test_reference_5() public pure {
        uint256[] memory xp = new uint256[](3);
        xp[0] = 123456789 ether; xp[1] = 987654321 ether; xp[2] = 5000000 ether;
        _near(StableMath.getD(xp, 2000), 1114396697783829596675782893);
        _near(StableMath.getY(0, 1, xp[0] + 50 ether, xp, 2000), 987654270386220438760556990);
    }

    function test_reverts_on_bad_input() public {
        uint256[] memory one = new uint256[](1);
        one[0] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(StableMath.BadLength.selector, 1));
        h.getD(one, 100);
        uint256[] memory xp = new uint256[](2);
        xp[0] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(StableMath.ZeroBalance.selector, 1));
        h.getD(xp, 100);
        xp[1] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(StableMath.BalanceTooSmall.selector, 0, 1));
        uint256[] memory dust = new uint256[](2);
        dust[0] = 1;
        dust[1] = 1;
        h.getD(dust, 100);
        vm.expectRevert(abi.encodeWithSelector(StableMath.BadAmp.selector, 9));
        h.getD(xp, 9);
        vm.expectRevert(abi.encodeWithSelector(StableMath.SameIndex.selector, 0));
        h.quoteSwap(xp, 100, 0, 0, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(StableMath.IndexOutOfRange.selector, 2, 2));
        h.quoteSwap(xp, 100, 0, 2, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(StableMath.BadFee.selector, 10_000));
        h.quoteSwap(xp, 100, 0, 1, 1, 10_000);
        uint256[] memory four = new uint256[](4);
        vm.expectRevert(abi.encodeWithSelector(StableMath.BadLength.selector, 4));
        h.getD(four, 100);
    }

    /// Regression for the fuzz finding: 1e30 vs 4.3e12 at A=2 never converged; now refused up front.
    function test_regression_extreme_imbalance_refused() public {
        uint256[] memory xp = new uint256[](2);
        xp[0] = 1e26;
        xp[1] = 1e22;
        vm.expectRevert(abi.encodeWithSelector(StableMath.TooImbalanced.selector, 1e26, 1e22));
        h.getD(xp, 100);
        xp[0] = 1e22;
        xp[1] = 1e20; // 100:1 is inside; a trade that pushes coin 0 past 1000:1 is refused
        vm.expectRevert(abi.encodeWithSelector(StableMath.TooImbalanced.selector, 1e22 + 1e23, 1e20));
        h.quoteSwap(xp, 100, 0, 1, 1e23, 0);
    }

    function test_zero_in_zero_out() public pure {
        uint256[] memory xp = new uint256[](2);
        xp[0] = 1000 ether;
        xp[1] = 1000 ether;
        assertEq(StableMath.quoteSwap(xp, 100, 0, 1, 0, 4), 0);
    }

    function _bal(uint256 n, uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory xp) {
        xp = new uint256[](n);
        xp[0] = bound(a, 1e15, 1e26);
        xp[1] = bound(b, xp[0] / 500 + 1, xp[0] * 500 > 1e26 ? 1e26 : xp[0] * 500);
        if (n == 3) {
            uint256 hi = xp[0] > xp[1] ? xp[0] : xp[1];
            uint256 lo = xp[0] < xp[1] ? xp[0] : xp[1];
            xp[2] = bound(c, hi / 500 + 1, lo * 500 > 1e26 ? 1e26 : lo * 500);
        }
    }

    /// No value from nothing: after a fee-free swap the invariant D of the new balances is not below the old D.
    function testFuzz_swap_never_lowers_D(uint256 a, uint256 b, uint256 c, uint256 amp, uint256 dx, bool three)
        public
        view
    {
        uint256 n = three ? 3 : 2;
        uint256[] memory xp = _bal(n, a, b, c);
        amp = bound(amp, 10, 5000);
        dx = bound(dx, 1, xp[0] / 2);
        uint256 d0 = StableMath.getD(xp, amp);
        uint256 dy;
        try h.quoteSwap(xp, amp, 0, 1, dx, 0) returns (uint256 out) {
            dy = out;
        } catch (bytes memory err) {
            // The only allowed refusals: the trade would leave the pool outside its envelope.
            bytes4 sel = bytes4(err);
            assertTrue(sel == StableMath.TooImbalanced.selector || sel == StableMath.BalanceTooSmall.selector);
            return;
        }
        assertLt(dy, xp[1]);
        xp[0] += dx;
        xp[1] -= dy;
        uint256 d1 = StableMath.getD(xp, amp);
        // getD stops within 1 wei; allow the same tolerance as the reference tests.
        uint256 tol = d0 / 1e15;
        if (tol < 2) tol = 2;
        assertGe(d1 + tol, d0);
    }

    /// Monotone: more in never gives less out; a fee never gives more out.
    function testFuzz_monotone(uint256 a, uint256 b, uint256 amp, uint256 dx, uint256 extra, uint256 fee) public view {
        uint256[] memory xp = _bal(2, a, b, 0);
        amp = bound(amp, 10, 5000);
        dx = bound(dx, 1, xp[0] / 2);
        extra = bound(extra, 0, xp[0] / 2);
        fee = bound(fee, 0, 9_999);
        uint256 small;
        try h.quoteSwap(xp, amp, 0, 1, dx, 0) returns (uint256 o) { small = o; } catch { return; }
        try h.quoteSwap(xp, amp, 0, 1, dx + extra, 0) returns (uint256 big) { assertGe(big, small); } catch {}
        assertLe(StableMath.quoteSwap(xp, amp, 0, 1, dx, fee), small);
    }

    /// Balanced pool, high A, small trade: price is close to 1:1 but never better than 1:1.
    function testFuzz_balanced_near_par(uint256 bal, uint256 dx) public pure {
        bal = bound(bal, 1e21, 1e26);
        dx = bound(dx, 1e12, bal / 1000);
        uint256[] memory xp = new uint256[](2);
        xp[0] = bal;
        xp[1] = bal;
        uint256 dy = StableMath.quoteSwap(xp, 2000, 0, 1, dx, 0);
        assertLe(dy, dx);
        assertGe(dy, dx - dx / 1000);
    }
}
