// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited. TESTNET MOCK ONLY. Has no value, is not FLOP or USDC, and is not tradable: a transfer must start or end
/// at a protocol contract the owner allowlisted, so no wallet-to-wallet or pool trading. Anyone may mint, capped per call.

import {ERC20} from "solady/tokens/ERC20.sol";
import {Owned2Step} from "../Owned2Step.sol";

contract TestToken is ERC20, Owned2Step {
    error NotTradable();
    error MintAboveCap();

    event EndpointSet(address indexed endpoint, bool allowed);

    uint256 public immutable mintCapPerCall;
    uint8 internal immutable _decimals;
    string internal _name;
    string internal _symbol;

    mapping(address => bool) public isEndpoint;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 mintCapPerCall_, address owner_)
        Owned2Step(owner_)
    {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        mintCapPerCall = mintCapPerCall_;
    }

    // ---- owner ----

    /// Allowlists a protocol contract (vault, strategy, market) as one side of every transfer.
    function setEndpoint(address endpoint, bool allowed) external onlyOwner {
        isEndpoint[endpoint] = allowed;
        emit EndpointSet(endpoint, allowed);
    }

    // ---- anyone ----

    function mint(address to, uint256 amount) external {
        if (amount > mintCapPerCall) revert MintAboveCap();
        _mint(to, amount);
    }

    // ---- views ----

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ---- internal ----

    /// Mints (from == 0) pass; every other move needs an allowlisted protocol contract on one side.
    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (from != address(0) && !isEndpoint[from] && !isEndpoint[to]) revert NotTradable();
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}
