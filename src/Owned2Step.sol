// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited prototype. Not deployed. Two-step ownership with an expiring handover (TASTE #13).
abstract contract Owned2Step {
    error NotOwner();
    error NotPendingOwner();
    error HandoverExpired();
    error ZeroAddress();

    event OwnershipHandoverStarted(address indexed pendingOwner, uint256 expiresAt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    uint256 public constant HANDOVER_WINDOW = 48 hours;

    address public owner;
    address public pendingOwner;
    uint256 public handoverExpiresAt;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// Owner names a successor; nothing changes until the successor accepts inside the window.
    function startOwnershipHandover(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        pendingOwner = next;
        handoverExpiresAt = block.timestamp + HANDOVER_WINDOW;
        emit OwnershipHandoverStarted(next, handoverExpiresAt);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        if (block.timestamp > handoverExpiresAt) revert HandoverExpired();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
        handoverExpiresAt = 0;
    }
}
