// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title StableMath
/// @notice StableSwap invariant math for 2 or 3 balances already normalized to one unit
///         (for this repo: "inference units", e.g. 1e18 = the cost of 1M tokens of a reference model).
/// @dev Clean-room from the StableSwap paper (Egorov, 2019, https://curve.fi/files/stableswap-paper.pdf):
///      A n^n sum(x) + D = A D n^n + D^(n+1) / (n^n prod(x)). Newton's method for D and for one balance y.
///      Pure functions only. No token, no LP shares, no storage: a pool built on this needs palmer's OK
///      because LP shares are a token.
///      Rounding: getD rounds as Newton converges (within 1 wei); swap output is rounded DOWN and reduced
///      by 1 unit so the pool, never the caller, keeps rounding dust. Tests check D never falls on a swap.
library StableMath {
    uint256 internal constant MAX_ITER = 255;
    // Operating envelope. Outside it integer Newton can oscillate by a few wei (found by fuzzing, reproduced in
    // scripts/stable_ref.py --grid) or overflow, so the math refuses instead of pricing. A stable pool that is
    // more than 1000:1 imbalanced has already failed at its job; halting is the honest answer.
    uint256 internal constant MIN_A = 10;
    uint256 internal constant MAX_A = 1_000_000;
    uint256 internal constant MIN_BALANCE = 1e12;
    uint256 internal constant MAX_BALANCE = 1e27;
    uint256 internal constant MAX_RATIO = 1_000;
    uint256 internal constant BPS = 10_000;

    error BadLength(uint256 n);
    error BadAmp(uint256 a);
    error ZeroBalance(uint256 index);
    error BalanceTooSmall(uint256 index, uint256 balance);
    error BalanceTooLarge(uint256 index, uint256 balance);
    error TooImbalanced(uint256 maxBalance, uint256 minBalance);
    error SameIndex(uint256 i);
    error IndexOutOfRange(uint256 index, uint256 n);
    error NoConvergence();
    error BadFee(uint256 feeBps);
    error InsufficientLiquidity(uint256 dy, uint256 balance);

    function _check(uint256[] memory xp, uint256 amp) private pure {
        uint256 n = xp.length;
        if (n < 2 || n > 3) revert BadLength(n);
        if (amp < MIN_A || amp > MAX_A) revert BadAmp(amp);
        uint256 lo = type(uint256).max;
        uint256 hi;
        for (uint256 k; k < n; ++k) {
            uint256 x = xp[k];
            if (x == 0) revert ZeroBalance(k);
            if (x < MIN_BALANCE) revert BalanceTooSmall(k, x);
            if (x > MAX_BALANCE) revert BalanceTooLarge(k, x);
            if (x < lo) lo = x;
            if (x > hi) hi = x;
        }
        if (hi > lo * MAX_RATIO) revert TooImbalanced(hi, lo);
    }

    /// @notice The invariant D for balances xp and amplification amp.
    function getD(uint256[] memory xp, uint256 amp) internal pure returns (uint256) {
        _check(xp, amp);
        uint256 n = xp.length;
        uint256 s;
        for (uint256 k; k < n; ++k) s += xp[k];
        uint256 ann = amp * n ** n;
        uint256 d = s;
        for (uint256 it; it < MAX_ITER; ++it) {
            uint256 dP = d;
            for (uint256 k; k < n; ++k) dP = dP * d / (xp[k] * n);
            uint256 prev = d;
            d = (ann * s + dP * n) * d / ((ann - 1) * d + (n + 1) * dP);
            if (d > prev ? d - prev <= 1 : prev - d <= 1) return d;
        }
        revert NoConvergence();
    }

    /// @notice Balance of coin j that keeps D fixed when coin i's balance becomes x.
    function getY(uint256 i, uint256 j, uint256 x, uint256[] memory xp, uint256 amp) internal pure returns (uint256) {
        uint256 n = xp.length;
        if (i == j) revert SameIndex(i);
        if (i >= n) revert IndexOutOfRange(i, n);
        if (j >= n) revert IndexOutOfRange(j, n);
        uint256 d = getD(xp, amp);
        // The post-trade balances must sit inside the envelope too (checked on a copy; xp is not mutated).
        uint256[] memory nxt = new uint256[](n);
        for (uint256 k; k < n; ++k) nxt[k] = k == i ? x : xp[k];
        nxt[j] = nxt[i] < xp[j] ? nxt[i] : xp[j]; // j's new value is unknown yet; exclude it from the ratio check
        _check(nxt, amp);
        uint256 ann = amp * n ** n;
        uint256 c = d;
        uint256 s;
        for (uint256 k; k < n; ++k) {
            if (k == j) continue;
            uint256 xk = k == i ? x : xp[k];
            s += xk;
            c = c * d / (xk * n);
        }
        c = c * d / (ann * n);
        uint256 b = s + d / ann;
        uint256 y = d;
        for (uint256 it; it < MAX_ITER; ++it) {
            uint256 prev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (y > prev ? y - prev <= 1 : prev - y <= 1) return y;
        }
        revert NoConvergence();
    }

    /// @notice Output of coin j for dx of coin i, after a fee in basis points. Rounded against the caller.
    function quoteSwap(uint256[] memory xp, uint256 amp, uint256 i, uint256 j, uint256 dx, uint256 feeBps)
        internal
        pure
        returns (uint256 dy)
    {
        if (feeBps >= BPS) revert BadFee(feeBps);
        if (dx == 0) return 0;
        uint256 y = getY(i, j, xp[i] + dx, xp, amp);
        // -1: Newton lands within 1 unit; the pool keeps that unit, not the caller.
        if (y + 1 >= xp[j]) return 0;
        dy = xp[j] - y - 1;
        dy -= dy * feeBps / BPS + (dy * feeBps % BPS == 0 ? 0 : 1); // fee rounds up
        if (dy >= xp[j]) revert InsufficientLiquidity(dy, xp[j]);
        // The state after the trade must also be inside the envelope, or the next quote could not be priced.
        uint256[] memory fin = new uint256[](xp.length);
        for (uint256 k; k < xp.length; ++k) fin[k] = xp[k];
        fin[i] += dx;
        fin[j] -= dy;
        _check(fin, amp);
    }
}
