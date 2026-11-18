// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// The vault's only view of a compute strategy. Accounting is internal (never balanceOf), so donations do not move it.
interface IComputeStrategy {
    /// Assets the strategy owes the vault: free balance plus escrow reserved for open channels.
    function totalAssets() external view returns (uint256);
    /// Assets the vault can pull back right now (not reserved in a channel).
    function freeAssets() external view returns (uint256);
    /// Vault-only. Pulls `assets` from the vault.
    function deposit(uint256 assets) external;
    /// Vault-only. Sends `assets` of free balance back to the vault.
    function withdraw(uint256 assets) external;
}
