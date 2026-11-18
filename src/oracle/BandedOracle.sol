// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited prototype. Two independent feeds must agree within a band, be fresh and nonzero, or the read reverts.
/// Fail closed (TASTE #9, LESSONS §3): no fallback to one feed, no last-good price.

import {IOracle, IPriceFeed} from "../interfaces/IOracle.sol";

contract BandedOracle is IOracle {
    error OracleZero();
    error OracleStale();
    error OracleBand();
    error BadConfig();

    uint256 public constant MAX_BPS = 10_000;

    IPriceFeed public immutable primary;
    IPriceFeed public immutable secondary;
    uint256 public immutable bandBps;
    uint256 public immutable maxAge;

    constructor(IPriceFeed primary_, IPriceFeed secondary_, uint256 bandBps_, uint256 maxAge_) {
        if (address(primary_) == address(secondary_) || bandBps_ == 0 || bandBps_ >= MAX_BPS || maxAge_ == 0) {
            revert BadConfig();
        }
        primary = primary_;
        secondary = secondary_;
        bandBps = bandBps_;
        maxAge = maxAge_;
    }

    /// Returns the primary price only if the secondary agrees within bandBps of the secondary.
    function price() external view returns (uint256) {
        uint256 p = _read(primary);
        uint256 r = _read(secondary);
        uint256 diff = p > r ? p - r : r - p;
        // diff / r > band / MAX_BPS, compared without division so no rounding hides a breach.
        if (diff * MAX_BPS > r * bandBps) revert OracleBand();
        return p;
    }

    function _read(IPriceFeed feed) internal view returns (uint256 p) {
        uint256 updatedAt;
        (p, updatedAt) = feed.latest();
        if (p == 0) revert OracleZero();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert OracleStale();
    }
}
