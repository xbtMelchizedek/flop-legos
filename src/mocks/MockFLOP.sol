// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// Test-only stand-in. There is no FLOP token (docs.flop.network official-links); this is not one.
contract MockFLOP is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock FLOP (test only)";
    }

    function symbol() public pure override returns (string memory) {
        return "mFLOP";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
