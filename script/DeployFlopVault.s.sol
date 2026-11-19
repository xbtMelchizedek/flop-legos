// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited. TESTNET ONLY. Deploys TEST mocks + FlopVault stack to Robinhood Chain testnet (or anvil with its chain id).
/// Run through scripts/rhc.sh, which reads the key file and refuses other chains. Writes deployments/<chainid>.json.

import {FlopVaultDeployment} from "./FlopVaultDeployment.sol";
import {FlopVault} from "../src/FlopVault.sol";
import {IsolatedMarket} from "../src/IsolatedMarket.sol";
import {MockComputeStrategy} from "../src/mocks/MockComputeStrategy.sol";
import {MockFeed} from "../src/mocks/MockFeed.sol";
import {TestToken} from "../src/mocks/TestToken.sol";
import {BandedOracle} from "../src/oracle/BandedOracle.sol";

contract DeployFlopVault is FlopVaultDeployment {
    // Every value below is an arbitrary test parameter, not market data. FLOP has no token and no price.
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant FLOP_DECIMALS = 18;
    uint256 internal constant USDC_MINT_CAP = 1_000_000e6;
    uint256 internal constant FLOP_MINT_CAP = 1_000_000e18;
    uint256 internal constant VAULT_DEPOSIT_CAP = 1_000_000e6;
    uint256 internal constant EPOCH_CAP = 10_000e6;
    /// 1 tUSDC base unit per G_n, in MockComputeStrategy.PRICE_SCALE units.
    uint256 internal constant MAX_PRICE_PER_GN = 1e18;
    /// Test peg: 1 tFLOP = 1 tUSDC, as loan base units per collateral base unit scaled 1e36.
    uint256 internal constant TEST_PRICE = 1e36 * 1e6 / 1e18;
    uint256 internal constant BAND_BPS = 200;
    uint256 internal constant MAX_AGE = 1 days;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant LIF = 1.05e18;
    uint256 internal constant RATE_PER_SECOND = 1e9;

    /// Mock miner: an address with no known key, so paid tUSDC-TEST is simply parked.
    address public constant MOCK_MINER = address(uint160(uint256(keccak256("flopvault.mock-miner.v1"))));

    function run() external returns (Deployment memory d) {
        d = deploy(_deployerKey());
        _write(d);
    }

    /// Testnet simplification: the deployer holds every role (owner, governor, keeper, settler, guardian).
    function deploy(uint256 pk) public returns (Deployment memory d) {
        _requireTestnet();
        address me = vm.addr(pk);
        d.deployer = me;
        d.miner = MOCK_MINER;

        vm.startBroadcast(pk);
        TestToken usdc = new TestToken(
            "TEST tUSDC (testnet mock, no value, not tradable)", "tUSDC-TEST", USDC_DECIMALS, USDC_MINT_CAP, me
        );
        TestToken flop = new TestToken(
            "TEST tFLOP (not FLOP, no value, not tradable)", "tFLOP-TEST", FLOP_DECIMALS, FLOP_MINT_CAP, me
        );
        MockComputeStrategy strategy = new MockComputeStrategy(address(usdc), me, me, me, EPOCH_CAP, MAX_PRICE_PER_GN);
        FlopVault vault = new FlopVault(address(usdc), USDC_DECIMALS, strategy, me, VAULT_DEPOSIT_CAP);
        strategy.setVault(address(vault));
        strategy.setMiner(MOCK_MINER, true);
        vault.setKeeper(me);
        vault.setGuardian(me);

        MockFeed primaryFeed = new MockFeed();
        MockFeed secondaryFeed = new MockFeed();
        primaryFeed.set(TEST_PRICE);
        secondaryFeed.set(TEST_PRICE);
        BandedOracle oracle = new BandedOracle(primaryFeed, secondaryFeed, BAND_BPS, MAX_AGE);
        IsolatedMarket market = new IsolatedMarket(address(usdc), address(flop), oracle, LLTV, LIF, RATE_PER_SECOND);

        usdc.setEndpoint(address(vault), true);
        usdc.setEndpoint(address(strategy), true);
        usdc.setEndpoint(address(market), true);
        flop.setEndpoint(address(market), true);
        vm.stopBroadcast();

        d.tUSDC = address(usdc);
        d.tFLOP = address(flop);
        d.strategy = address(strategy);
        d.vault = address(vault);
        d.primaryFeed = address(primaryFeed);
        d.secondaryFeed = address(secondaryFeed);
        d.oracle = address(oracle);
        d.market = address(market);
    }
}
