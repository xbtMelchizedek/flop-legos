// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited prototype. Not deployed. No token. Local tests against mocks only.
/// ERC-4626 vault over one compute budget asset (mock FLOP). Spec: docs/SPEC.md §1.

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IComputeStrategy} from "./interfaces/IComputeStrategy.sol";
import {Owned2Step} from "./Owned2Step.sol";

contract ComputeVault is ERC20, ReentrancyGuardTransient, Owned2Step {
    using FixedPointMathLib for uint256;

    error ZeroShares();
    error ZeroAssets();
    error NotKeeper();
    error NotGuardian();
    error DepositsPaused();
    error ExceedsMaxDeposit();
    error ExceedsMaxWithdraw();
    error FeeOnTransferRefused();
    error NoCode();

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Allocated(uint256 assets);
    event Deallocated(uint256 assets);
    event KeeperSet(address indexed keeper);
    event GuardianSet(address indexed guardian);
    event DepositCapSet(uint256 cap);
    event PausedSet(bool paused);

    /// Virtual shares and one virtual asset (TASTE #5): an empty-vault donation cannot round a victim to zero shares.
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;
    uint8 public constant DECIMALS_OFFSET = 6;

    address public immutable asset;
    IComputeStrategy public immutable strategy;
    uint8 internal immutable _assetDecimals;

    /// Assets held by the vault itself, tracked internally. Tokens sent directly are ignored.
    uint256 public idle;
    uint256 public depositCap;
    bool public paused;
    address public keeper;
    address public guardian;

    constructor(address asset_, uint8 assetDecimals_, IComputeStrategy strategy_, address owner_, uint256 depositCap_)
        Owned2Step(owner_)
    {
        if (asset_.code.length == 0 || address(strategy_).code.length == 0) revert NoCode();
        asset = asset_;
        _assetDecimals = assetDecimals_;
        strategy = strategy_;
        depositCap = depositCap_;
    }

    // ---- owner (governance) ----

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    /// Only the owner unpauses; the guardian can pause but never unpause.
    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    // ---- guardian ----

    /// Stops deposits and allocation. Withdrawals stay open so nobody's budget is trapped.
    function pause() external {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        paused = true;
        emit PausedSet(true);
    }

    // ---- keeper ----

    function allocate(uint256 assets) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (paused) revert DepositsPaused();
        idle -= assets;
        emit Allocated(assets);
        SafeTransferLib.safeApprove(asset, address(strategy), assets);
        strategy.deposit(assets);
    }

    function deallocate(uint256 assets) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        _pullFromStrategy(assets);
        emit Deallocated(assets);
    }

    // ---- ERC-4626 entry points ----

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets > maxDeposit(receiver)) revert ExceedsMaxDeposit();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        _pullIn(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        assets = previewMint(shares);
        if (assets == 0) revert ZeroAssets();
        if (assets > maxDeposit(receiver)) revert ExceedsMaxDeposit();
        _pullIn(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external nonReentrant returns (uint256 shares) {
        if (assets > maxWithdraw(owner_)) revert ExceedsMaxWithdraw();
        shares = previewWithdraw(assets);
        _exit(assets, shares, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        if (shares > maxRedeem(owner_)) revert ExceedsMaxWithdraw();
        assets = previewRedeem(shares);
        if (assets == 0) revert ZeroAssets();
        _exit(assets, shares, receiver, owner_);
    }

    // ---- views ----

    function name() public pure override returns (string memory) {
        return "flop-legos compute vault (prototype)";
    }

    function symbol() public pure override returns (string memory) {
        return "lcFLOP";
    }

    function decimals() public view override returns (uint8) {
        return _assetDecimals + DECIMALS_OFFSET;
    }

    function totalAssets() public view returns (uint256) {
        return idle + strategy.totalAssets();
    }

    /// Exit mark: only liquid assets. Escrow reserved for compute is valued at zero for anyone leaving, so a holder
    /// cannot exit ahead of a pending settlement and leave the consumption to others. Entry uses the full mark.
    /// Entering at the high mark and leaving at the low mark means a round trip can never profit (docs/SPEC.md §1.3).
    function exitAssets() public view returns (uint256) {
        return idle + strategy.freeAssets();
    }

    /// Rounds down. Informational (ERC-4626): uses the full mark.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.fullMulDiv(totalSupply() + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    /// Rounds down. Informational (ERC-4626): uses the full mark.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.fullMulDiv(totalAssets() + VIRTUAL_ASSETS, totalSupply() + VIRTUAL_SHARES);
    }

    /// Rounds down: the caller never gets a share the vault did not receive assets for.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return assets.fullMulDiv(totalSupply() + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    /// Rounds up: minting a share costs at least its full value.
    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.fullMulDivUp(totalAssets() + VIRTUAL_ASSETS, totalSupply() + VIRTUAL_SHARES);
    }

    /// Rounds up, at the exit mark: taking assets out burns at least their full value in shares.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.fullMulDivUp(totalSupply() + VIRTUAL_SHARES, exitAssets() + VIRTUAL_ASSETS);
    }

    /// Rounds down, at the exit mark.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares.fullMulDiv(exitAssets() + VIRTUAL_ASSETS, totalSupply() + VIRTUAL_SHARES);
    }

    function maxDeposit(address) public view returns (uint256) {
        if (paused) return 0;
        uint256 total = totalAssets();
        return total >= depositCap ? 0 : depositCap - total;
    }

    function maxMint(address receiver) external view returns (uint256) {
        return previewDeposit(maxDeposit(receiver));
    }

    function maxWithdraw(address owner_) public view returns (uint256) {
        return FixedPointMathLib.min(previewRedeem(balanceOf(owner_)), exitAssets());
    }

    function maxRedeem(address owner_) public view returns (uint256) {
        uint256 shares = balanceOf(owner_);
        uint256 liquid = exitAssets();
        if (previewRedeem(shares) <= liquid) return shares;
        // Largest share count whose rounded-down redemption still fits in the liquid assets.
        return FixedPointMathLib.min(shares, liquid.fullMulDiv(totalSupply() + VIRTUAL_SHARES, liquid + VIRTUAL_ASSETS));
    }

    // ---- internal ----

    function _exit(uint256 assets, uint256 shares, address receiver, address owner_) internal {
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        if (assets > idle) _pullFromStrategy(assets - idle);
        idle -= assets;
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
        SafeTransferLib.safeTransfer(asset, receiver, assets);
    }

    /// Fee-on-transfer and rebasing-down tokens are refused, not half-supported (LESSONS pre-ship: tokens).
    function _pullIn(uint256 assets) internal {
        uint256 before = SafeTransferLib.balanceOf(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets);
        if (SafeTransferLib.balanceOf(asset, address(this)) - before != assets) revert FeeOnTransferRefused();
        idle += assets;
    }

    function _pullFromStrategy(uint256 assets) internal {
        uint256 before = SafeTransferLib.balanceOf(asset, address(this));
        strategy.withdraw(assets);
        if (SafeTransferLib.balanceOf(asset, address(this)) - before != assets) revert FeeOnTransferRefused();
        idle += assets;
    }

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
