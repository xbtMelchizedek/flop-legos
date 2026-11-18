// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited prototype. Mock only: models a FLOP compute channel (escrow -> verdict -> miner paid, rest refunded).
/// The real thing would be a FLOP-side agent wallet driven off-chain; FLOP has no contracts (see docs/SPEC.md §0).

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IComputeStrategy} from "../interfaces/IComputeStrategy.sol";

contract MockComputeStrategy is IComputeStrategy, ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;

    error NotVault();
    error NotKeeper();
    error NotSettler();
    error NotGovernor();
    error VaultAlreadySet();
    error MinerNotAllowed();
    error EpochCapExceeded();
    error InsufficientFree();
    error ChannelNotOpen();
    error TooEarly();
    error TooLate();
    error PriceAboveCap();

    event VaultSet(address indexed vault);
    event MinerAllowed(address indexed miner, bool allowed);
    event ChannelOpened(
        uint256 indexed id, address indexed miner, uint256 escrow, uint256 pricePerGn, uint256 deadline
    );
    event ChannelSettled(uint256 indexed id, address indexed miner, uint256 workGn, uint256 paid, uint256 refunded);
    event ChannelRefunded(uint256 indexed id, uint256 refunded);

    enum Status {
        None,
        Open,
        Settled,
        Refunded
    }

    struct Channel {
        address miner;
        uint96 deadline;
        uint256 escrow;
        uint256 pricePerGn;
        Status status;
    }

    /// Price unit: asset base units per G_n, scaled by PRICE_SCALE.
    uint256 public constant PRICE_SCALE = 1e18;
    /// FLOP's agent-wallet cap window is 86,400 blocks (yellowpaper 0.5.0 §6.2 R6.2b); mocked here in seconds.
    uint256 public constant EPOCH = 86_400;
    uint256 public constant CHANNEL_TTL = 4 hours;

    address public immutable asset;
    address public immutable governor;
    address public immutable keeper;
    /// Stands in for the FLOP validators' settlement verdict.
    address public immutable settler;
    uint256 public immutable epochCap;
    uint256 public immutable maxPricePerGn;

    address public vault;
    uint256 public free;
    uint256 public reserved;
    uint256 public paidToMiners;
    uint256 public workDeliveredGn;
    uint256 public epochStart;
    uint256 public spentThisEpoch;
    uint256 public nextId = 1;
    mapping(uint256 => Channel) public channels;
    mapping(address => bool) public allowedMiner;

    constructor(
        address asset_,
        address governor_,
        address keeper_,
        address settler_,
        uint256 epochCap_,
        uint256 maxPricePerGn_
    ) {
        asset = asset_;
        governor = governor_;
        keeper = keeper_;
        settler = settler_;
        epochCap = epochCap_;
        maxPricePerGn = maxPricePerGn_;
    }

    // ---- governor ----

    /// One-shot: the vault address is fixed once set.
    function setVault(address vault_) external {
        if (msg.sender != governor) revert NotGovernor();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function setMiner(address miner, bool allowed) external {
        if (msg.sender != governor) revert NotGovernor();
        allowedMiner[miner] = allowed;
        emit MinerAllowed(miner, allowed);
    }

    // ---- vault ----

    function deposit(uint256 assets) external nonReentrant {
        if (msg.sender != vault) revert NotVault();
        free += assets;
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets);
    }

    function withdraw(uint256 assets) external nonReentrant {
        if (msg.sender != vault) revert NotVault();
        if (assets > free) revert InsufficientFree();
        free -= assets;
        SafeTransferLib.safeTransfer(asset, msg.sender, assets);
    }

    // ---- keeper: reserve compute ----

    /// Escrow counts against the epoch cap when reserved, not when paid (conservative, like R6.2b's daily cap).
    function openChannel(address miner, uint256 escrow, uint256 pricePerGn) external nonReentrant returns (uint256 id) {
        if (msg.sender != keeper) revert NotKeeper();
        if (!allowedMiner[miner]) revert MinerNotAllowed();
        if (pricePerGn > maxPricePerGn) revert PriceAboveCap();
        if (escrow > free) revert InsufficientFree();
        if (block.timestamp >= epochStart + EPOCH) {
            epochStart = block.timestamp;
            spentThisEpoch = 0;
        }
        if (spentThisEpoch + escrow > epochCap) revert EpochCapExceeded();
        spentThisEpoch += escrow;
        free -= escrow;
        reserved += escrow;
        id = nextId++;
        uint256 deadline = block.timestamp + CHANNEL_TTL;
        channels[id] = Channel(miner, uint96(deadline), escrow, pricePerGn, Status.Open);
        emit ChannelOpened(id, miner, escrow, pricePerGn, deadline);
    }

    // ---- settler: verdict ----

    /// Pays verified work at the channel price, rounded down (miner never overpaid); the rest returns to free.
    function settle(uint256 id, uint256 workGn) external nonReentrant {
        if (msg.sender != settler) revert NotSettler();
        Channel storage c = channels[id];
        if (c.status != Status.Open) revert ChannelNotOpen();
        if (block.timestamp > c.deadline) revert TooLate();
        uint256 paid = FixedPointMathLib.min(workGn.fullMulDiv(c.pricePerGn, PRICE_SCALE), c.escrow);
        uint256 refunded = c.escrow - paid;
        c.status = Status.Settled;
        reserved -= c.escrow;
        free += refunded;
        paidToMiners += paid;
        workDeliveredGn += workGn;
        emit ChannelSettled(id, c.miner, workGn, paid, refunded);
        if (paid != 0) SafeTransferLib.safeTransfer(asset, c.miner, paid);
    }

    // ---- anyone: keeper job ----

    /// Permissionless after the deadline: a timed-out channel always returns its escrow.
    function refundTimedOut(uint256 id) external nonReentrant {
        Channel storage c = channels[id];
        if (c.status != Status.Open) revert ChannelNotOpen();
        if (block.timestamp <= c.deadline) revert TooEarly();
        c.status = Status.Refunded;
        reserved -= c.escrow;
        free += c.escrow;
        emit ChannelRefunded(id, c.escrow);
    }

    // ---- views ----

    function totalAssets() external view returns (uint256) {
        return free + reserved;
    }

    function freeAssets() external view returns (uint256) {
        return free;
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
