// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceFeed} from "../interfaces/IOracle.sol";

/// Test-only feed. Anyone can set it; that is the point of a mock.
contract MockFeed is IPriceFeed {
    uint256 public p;
    uint256 public updatedAt;

    function set(uint256 price_) external {
        p = price_;
        updatedAt = block.timestamp;
    }

    function setWithTime(uint256 price_, uint256 updatedAt_) external {
        p = price_;
        updatedAt = updatedAt_;
    }

    function latest() external view returns (uint256, uint256) {
        return (p, updatedAt);
    }
}
