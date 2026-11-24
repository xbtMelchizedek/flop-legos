// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FlopVault} from "../src/FlopVault.sol";
import {MockComputeStrategy} from "../src/mocks/MockComputeStrategy.sol";

/// Deploys the flop-legos compute vault prototype to HyperEVM testnet (chain 998).
///
/// NOT APPROVED TO BROADCAST. FlopVault mints a share token (fvFLOP). Creating any token needs palmer's OK.
/// Without --broadcast, `forge script` only simulates. See DEPLOY_HYPEREVM.md.
///
/// What it deploys (2 contracts, no new asset token):
///   1. MockComputeStrategy: stands in for a FLOP compute channel (escrow -> verdict -> miner paid, rest refunded).
///   2. FlopVault: ERC-4626-style vault over an EXISTING asset, default canonical WHYPE (0x5555...5555).
/// StableMath is an internal library and is not deployed.
///
/// Env:
///   HYPEREVM_DEPLOYER_KEY   private key (only for the approved real run; read from the 600 secret file)
///   DEPLOYER_ADDR           address to simulate as when no key is set
///   VAULT_ASSET             asset address (default WHYPE)
///   VAULT_DEPOSIT_CAP       default 100e18 (100 WHYPE) so a testnet bug can't hold much
contract DeployHyperEVM is Script {
    error WrongChain(uint256 chainId);
    error AssetHasNoCode(address asset);
    error WiringFailed();

    uint256 internal constant HYPEREVM_TESTNET = 998;
    address internal constant WHYPE = 0x5555555555555555555555555555555555555555;

    // Strategy limits: per-epoch spend cap and max price per G_n, same units as the unit tests.
    uint256 internal constant EPOCH_CAP = 10e18;
    uint256 internal constant MAX_PRICE_PER_GN = 1e12;

    function run() external returns (FlopVault vault, MockComputeStrategy strategy) {
        if (block.chainid != HYPEREVM_TESTNET) revert WrongChain(block.chainid);

        address asset = vm.envOr("VAULT_ASSET", WHYPE);
        if (asset.code.length == 0) revert AssetHasNoCode(asset);
        uint256 cap = vm.envOr("VAULT_DEPOSIT_CAP", uint256(100e18));

        uint256 key = vm.envOr("HYPEREVM_DEPLOYER_KEY", uint256(0));
        address deployer;
        if (key != 0) {
            deployer = vm.addr(key);
            vm.startBroadcast(key);
        } else {
            deployer = vm.envAddress("DEPLOYER_ADDR");
            vm.startBroadcast(deployer);
        }

        // Testnet: one throwaway key holds every role. Mainnet would split governor/keeper/settler/guardian.
        strategy = new MockComputeStrategy(asset, deployer, deployer, deployer, EPOCH_CAP, MAX_PRICE_PER_GN);
        vault = new FlopVault(asset, 18, strategy, deployer, cap);
        strategy.setVault(address(vault)); // one-shot
        vault.setKeeper(deployer);
        vault.setGuardian(deployer);
        // No miner is allowlisted: allocate() can move funds to the strategy but no channel can open
        // until the governor names a miner. That's deliberate for a first deploy.

        vm.stopBroadcast();

        if (strategy.vault() != address(vault) || vault.asset() != asset || vault.owner() != deployer) {
            revert WiringFailed();
        }
        console.log("deployer", deployer);
        console.log("strategy", address(strategy));
        console.log("vault", address(vault));
        console.log("share", vault.name(), vault.symbol());
        console.log("share decimals", vault.decimals());
    }
}
