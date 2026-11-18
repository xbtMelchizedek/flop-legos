// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Loan-token units per one collateral unit, scaled by 1e36. Reverts instead of returning a bad price.
interface IOracle {
    function price() external view returns (uint256);
}

/// A raw feed. May return zero or a stale timestamp; BandedOracle decides.
interface IPriceFeed {
    function latest() external view returns (uint256 price, uint256 updatedAt);
}
