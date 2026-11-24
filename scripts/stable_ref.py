#!/usr/bin/env python3
"""Reference StableSwap values by a different method (bisection on the exact invariant, 80-digit Decimal).
Prints Solidity literals for test/unit/StableMath.t.sol. Not the same algorithm as the contract, on purpose."""
from decimal import Decimal as Dm, getcontext
getcontext().prec = 80

def f(D, xs, A):
    n = len(xs); ann = Dm(A) * n**n; S = sum(xs); P = Dm(1)
    for x in xs: P *= x
    return ann * S + D - ann * D - D**(n + 1) / (Dm(n)**n * P)

def solve_D(xs, A):
    lo, hi = Dm(0), sum(xs) * 2
    for _ in range(400):
        mid = (lo + hi) / 2
        (lo, hi) = (mid, hi) if f(mid, xs, A) > 0 else (lo, mid)
    return lo

def solve_y(xs, A, i, j, x):
    D = solve_D(xs, A); ys = list(xs); ys[i] = x
    lo, hi = Dm(0), D * 4
    for _ in range(400):
        mid = (lo + hi) / 2; ys[j] = mid
        # invariant residual increases with y at fixed D
        (lo, hi) = (lo, mid) if f(D, ys, A) > 0 else (mid, hi)
    return lo

E = Dm(10)**18
cases = [
    ([1000 * E, 1000 * E], 100),
    ([1000 * E, 500 * E], 100),
    ([10 * E, 9000 * E], 50),
    ([1000 * E, 1000 * E, 1000 * E], 200),
    ([3000 * E, 1000 * E, 20 * E], 10),
    ([123456789 * E, 987654321 * E, 5000000 * E], 2000),
]
for xs, A in cases:
    D = solve_D([Dm(x) for x in xs], A)
    x_new = Dm(xs[0]) + 50 * E
    y = solve_y([Dm(x) for x in xs], A, 0, 1, x_new)
    print(f"// xp={[int(x // E) for x in xs]}e18 A={A}")
    print(f"D={int(D)} y(0->1, +50e18)={int(y)}")
