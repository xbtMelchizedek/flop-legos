// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// Takes 1% on every transfer. Vault and market must refuse it.
contract FeeOnTransferToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Fee token";
    }

    function symbol() public pure override returns (string memory) {
        return "FEE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = amount / 100;
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        return true;
    }
}

/// Calls back into a target during transferFrom, the way an ERC-777 hook or a malicious token would.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentryOk;
    bytes4 public reentryError;

    function name() public pure override returns (string memory) {
        return "Hook token";
    }

    function symbol() public pure override returns (string memory) {
        return "HOOK";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            reentryOk = ok;
            if (!ok && ret.length >= 4) reentryError = bytes4(ret);
        }
        return super.transferFrom(from, to, amount);
    }
}
