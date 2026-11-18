// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited prototype. Not deployed. One collateral, one loan asset, one oracle, fixed parameters, no owner.
/// The isolated-market shape is learned from Morpho Blue (GPL, read only); this code is ours. Spec: docs/SPEC.md §2.

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IOracle} from "./interfaces/IOracle.sol";

contract IsolatedMarket is ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;

    error ZeroAmount();
    error NoCode();
    error BadConfig();
    error Unhealthy();
    error Healthy();
    error InsufficientLiquidity();
    error FeeOnTransferRefused();

    event Supplied(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 assets, uint256 shares);
    event CollateralSupplied(address indexed account, uint256 assets);
    event CollateralWithdrawn(address indexed account, uint256 assets);
    event Borrowed(address indexed account, uint256 assets, uint256 shares);
    event Repaid(address indexed payer, address indexed account, uint256 assets, uint256 shares);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 repaidAssets, uint256 seized, uint256 badDebt
    );
    event Accrued(uint256 interest);

    struct Position {
        uint256 supplyShares;
        uint256 borrowShares;
        uint256 collateral;
    }

    uint256 public constant WAD = 1e18;
    uint256 public constant ORACLE_SCALE = 1e36;
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    address public immutable loanToken;
    address public immutable collateralToken;
    IOracle public immutable oracle;
    /// Liquidation LTV, WAD. A position is healthy while debt <= collateral value * lltv.
    uint256 public immutable lltv;
    /// Liquidation incentive factor, WAD (e.g. 1.05e18).
    uint256 public immutable lif;
    /// Simple interest per second on borrowed assets, WAD. Fixed: no rate model, no governance.
    uint256 public immutable ratePerSecond;

    uint256 public totalSupplyAssets;
    uint256 public totalSupplyShares;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrual;
    mapping(address => Position) public positions;

    constructor(
        address loanToken_,
        address collateralToken_,
        IOracle oracle_,
        uint256 lltv_,
        uint256 lif_,
        uint256 ratePerSecond_
    ) {
        if (loanToken_.code.length == 0 || collateralToken_.code.length == 0 || address(oracle_).code.length == 0) {
            revert NoCode();
        }
        // lif * lltv < 1 keeps a liquidation from seizing more value than the debt it clears at the threshold.
        if (loanToken_ == collateralToken_ || lltv_ == 0 || lif_ < WAD || lltv_.mulWad(lif_) >= WAD) {
            revert BadConfig();
        }
        loanToken = loanToken_;
        collateralToken = collateralToken_;
        oracle = oracle_;
        lltv = lltv_;
        lif = lif_;
        ratePerSecond = ratePerSecond_;
        lastAccrual = block.timestamp;
    }

    // ---- lenders (no price needed) ----

    function supply(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = _toSharesDown(assets, totalSupplyAssets, totalSupplyShares);
        if (shares == 0) revert ZeroAmount();
        positions[msg.sender].supplyShares += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += assets;
        emit Supplied(msg.sender, assets, shares);
        _pullIn(loanToken, assets);
    }

    function withdraw(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = _toSharesUp(assets, totalSupplyAssets, totalSupplyShares);
        positions[msg.sender].supplyShares -= shares;
        totalSupplyShares -= shares;
        totalSupplyAssets -= assets;
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        emit Withdrawn(msg.sender, assets, shares);
        SafeTransferLib.safeTransfer(loanToken, msg.sender, assets);
    }

    // ---- borrowers ----

    function supplyCollateral(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        positions[msg.sender].collateral += assets;
        emit CollateralSupplied(msg.sender, assets);
        _pullIn(collateralToken, assets);
    }

    function withdrawCollateral(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        Position storage p = positions[msg.sender];
        p.collateral -= assets;
        // No debt, no price needed: a debt-free account can leave even while the oracle is failing closed.
        if (p.borrowShares != 0 && !_isHealthy(p, oracle.price())) revert Unhealthy();
        emit CollateralWithdrawn(msg.sender, assets);
        SafeTransferLib.safeTransfer(collateralToken, msg.sender, assets);
    }

    function borrow(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        shares = _toSharesUp(assets, totalBorrowAssets, totalBorrowShares);
        positions[msg.sender].borrowShares += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += assets;
        if (!_isHealthy(positions[msg.sender], oracle.price())) revert Unhealthy();
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();
        emit Borrowed(msg.sender, assets, shares);
        SafeTransferLib.safeTransfer(loanToken, msg.sender, assets);
    }

    /// Repay by shares so a full repay leaves no dust; assets owed round up.
    function repay(uint256 shares, address account) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        _accrue();
        assets = _toAssetsUp(shares, totalBorrowAssets, totalBorrowShares);
        positions[account].borrowShares -= shares;
        totalBorrowShares -= shares;
        totalBorrowAssets = _zeroFloorSub(totalBorrowAssets, assets);
        emit Repaid(msg.sender, account, assets, shares);
        _pullIn(loanToken, assets);
    }

    // ---- liquidators ----

    /// Seize `seized` collateral from an unhealthy borrower and pay its value / lif in loan tokens (rounded up).
    /// If the borrower is left with no collateral, remaining debt is bad debt, written off against suppliers.
    function liquidate(address borrower, uint256 seized) external nonReentrant returns (uint256 repaidAssets) {
        if (seized == 0) revert ZeroAmount();
        _accrue();
        uint256 px = oracle.price();
        Position storage p = positions[borrower];
        if (_isHealthy(p, px)) revert Healthy();

        repaidAssets = seized.fullMulDivUp(px, ORACLE_SCALE).divWadUp(lif);
        uint256 repaidShares = _toSharesDown(repaidAssets, totalBorrowAssets, totalBorrowShares);
        p.collateral -= seized;
        p.borrowShares -= repaidShares;
        totalBorrowShares -= repaidShares;
        totalBorrowAssets = _zeroFloorSub(totalBorrowAssets, repaidAssets);

        uint256 badDebt;
        if (p.collateral == 0 && p.borrowShares != 0) {
            badDebt = FixedPointMathLib.min(
                totalBorrowAssets, _toAssetsUp(p.borrowShares, totalBorrowAssets, totalBorrowShares)
            );
            totalBorrowShares -= p.borrowShares;
            p.borrowShares = 0;
            totalBorrowAssets -= badDebt;
            totalSupplyAssets -= badDebt;
        }
        emit Liquidated(msg.sender, borrower, repaidAssets, seized, badDebt);
        _pullIn(loanToken, repaidAssets);
        SafeTransferLib.safeTransfer(collateralToken, msg.sender, seized);
    }

    // ---- anyone ----

    /// Brings interest up to date. Harmless to call; every money path accrues first anyway.
    function accrueInterest() external nonReentrant {
        _accrue();
    }

    // ---- views ----

    function borrowAssetsOf(address account) external view returns (uint256) {
        return _toAssetsUp(positions[account].borrowShares, totalBorrowAssets, totalBorrowShares);
    }

    function supplyAssetsOf(address account) external view returns (uint256) {
        return _toAssetsDown(positions[account].supplyShares, totalSupplyAssets, totalSupplyShares);
    }

    function isHealthy(address account) external view returns (bool) {
        return _isHealthy(positions[account], oracle.price());
    }

    // ---- internal ----

    /// Debt rounds up, collateral value rounds down: a borderline position counts as unhealthy.
    function _isHealthy(Position storage p, uint256 px) internal view returns (bool) {
        if (p.borrowShares == 0) return true;
        uint256 debt = _toAssetsUp(p.borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 maxDebt = p.collateral.fullMulDiv(px, ORACLE_SCALE).mulWad(lltv);
        return debt <= maxDebt;
    }

    /// Interest rounds down: suppliers are never credited interest that borrowers do not owe.
    function _accrue() internal {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;
        if (totalBorrowAssets == 0) return;
        uint256 interest = totalBorrowAssets.mulWad(ratePerSecond * dt);
        totalBorrowAssets += interest;
        totalSupplyAssets += interest;
        emit Accrued(interest);
    }

    function _pullIn(address token, uint256 assets) internal {
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), assets);
        if (SafeTransferLib.balanceOf(token, address(this)) - before != assets) revert FeeOnTransferRefused();
    }

    function _toSharesDown(uint256 assets, uint256 totalA, uint256 totalS) internal pure returns (uint256) {
        return assets.fullMulDiv(totalS + VIRTUAL_SHARES, totalA + VIRTUAL_ASSETS);
    }

    function _toSharesUp(uint256 assets, uint256 totalA, uint256 totalS) internal pure returns (uint256) {
        return assets.fullMulDivUp(totalS + VIRTUAL_SHARES, totalA + VIRTUAL_ASSETS);
    }

    function _toAssetsDown(uint256 shares, uint256 totalA, uint256 totalS) internal pure returns (uint256) {
        return shares.fullMulDiv(totalA + VIRTUAL_ASSETS, totalS + VIRTUAL_SHARES);
    }

    function _toAssetsUp(uint256 shares, uint256 totalA, uint256 totalS) internal pure returns (uint256) {
        return shares.fullMulDivUp(totalA + VIRTUAL_ASSETS, totalS + VIRTUAL_SHARES);
    }

    function _zeroFloorSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
