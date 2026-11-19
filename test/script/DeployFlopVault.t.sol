// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployFlopVault} from "../../script/DeployFlopVault.s.sol";
import {SmokeFlopVault} from "../../script/SmokeFlopVault.s.sol";
import {FlopVaultDeployment} from "../../script/FlopVaultDeployment.sol";
import {FlopVault} from "../../src/FlopVault.sol";
import {IsolatedMarket} from "../../src/IsolatedMarket.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";
import {TestToken} from "../../src/mocks/TestToken.sol";
import {BandedOracle} from "../../src/oracle/BandedOracle.sol";

/// Runs the same deploy and smoke code the scripts run, in-process, at Robinhood Chain testnet's chain id.
contract DeployFlopVaultTest is Test {
    uint256 internal constant RHC_TESTNET = 46630;
    uint256 internal constant RHC_MAINNET = 4663;

    DeployFlopVault internal deployer;
    SmokeFlopVault internal smoker;
    uint256 internal pk;
    address internal me;

    function setUp() public {
        (me, pk) = makeAddrAndKey("throwaway-test-deployer");
        deployer = new DeployFlopVault();
        smoker = new SmokeFlopVault();
    }

    function test_chainIdConstantMatchesDocs() public view {
        assertEq(deployer.RHC_TESTNET_CHAIN_ID(), RHC_TESTNET);
    }

    function test_refusesRobinhoodMainnet() public {
        vm.chainId(RHC_MAINNET);
        vm.expectRevert(abi.encodeWithSelector(FlopVaultDeployment.WrongChain.selector, RHC_MAINNET));
        deployer.deploy(pk);
    }

    function test_refusesAnvilDefaultChain() public {
        vm.chainId(31337);
        vm.expectRevert(abi.encodeWithSelector(FlopVaultDeployment.WrongChain.selector, 31337));
        deployer.deploy(pk);
    }

    function test_deployWiresEveryContract() public {
        vm.chainId(RHC_TESTNET);
        FlopVaultDeployment.Deployment memory d = deployer.deploy(pk);
        FlopVault vault = FlopVault(d.vault);
        MockComputeStrategy strategy = MockComputeStrategy(d.strategy);
        IsolatedMarket market = IsolatedMarket(d.market);
        TestToken usdc = TestToken(d.tUSDC);
        TestToken flop = TestToken(d.tFLOP);

        assertEq(d.deployer, me);
        assertEq(vault.asset(), d.tUSDC);
        assertEq(address(vault.strategy()), d.strategy);
        assertEq(vault.owner(), me);
        assertEq(vault.keeper(), me);
        assertEq(vault.guardian(), me);
        assertEq(vault.decimals(), 12);
        assertEq(strategy.vault(), d.vault);
        assertEq(strategy.asset(), d.tUSDC);
        assertTrue(strategy.allowedMiner(d.miner));
        assertEq(market.loanToken(), d.tUSDC);
        assertEq(market.collateralToken(), d.tFLOP);
        assertEq(address(market.oracle()), d.oracle);
        assertEq(address(BandedOracle(d.oracle).primary()), d.primaryFeed);
        assertEq(BandedOracle(d.oracle).price(), 1e24);

        assertEq(usdc.symbol(), "tUSDC-TEST");
        assertEq(flop.symbol(), "tFLOP-TEST");
        assertEq(usdc.decimals(), 6);
        assertEq(flop.decimals(), 18);
        assertTrue(usdc.isEndpoint(d.vault) && usdc.isEndpoint(d.strategy) && usdc.isEndpoint(d.market));
        assertTrue(flop.isEndpoint(d.market));
        assertFalse(flop.isEndpoint(d.vault));
    }

    /// The mock tokens stay untradable after deploy: a wallet cannot hand them to another wallet.
    function test_deployedMocksAreNotTradable() public {
        vm.chainId(RHC_TESTNET);
        FlopVaultDeployment.Deployment memory d = deployer.deploy(pk);
        TestToken usdc = TestToken(d.tUSDC);
        usdc.mint(me, 1e6);
        vm.prank(me);
        vm.expectRevert(TestToken.NotTradable.selector);
        usdc.transfer(makeAddr("buyer"), 1e6);
    }

    function test_smokeRoundTripPaysMinerAndConserves() public {
        vm.chainId(RHC_TESTNET);
        FlopVaultDeployment.Deployment memory d = deployer.deploy(pk);
        SmokeFlopVault.Result memory r = smoker.smoke(pk, d);
        assertEq(r.paidToMiner, 40e6);
        assertEq(TestToken(d.tUSDC).balanceOf(d.miner), 40e6);
        assertEq(r.channelId, 1);
        assertEq(TestToken(d.tUSDC).balanceOf(me), r.redeemed);
        assertEq(r.redeemed + 40e6 + FlopVault(d.vault).totalAssets(), 1_000e6);
        assertEq(FlopVault(d.vault).balanceOf(me), 0);
    }

    /// Adversarial: if the recorded miner is really the depositor, the miner-payment check must be what fails first.
    function test_smokeFlagsMinerWiredToDepositor() public {
        vm.chainId(RHC_TESTNET);
        FlopVaultDeployment.Deployment memory d = deployer.deploy(pk);
        vm.prank(me);
        MockComputeStrategy(d.strategy).setMiner(me, true);
        d.miner = me;
        vm.expectRevert(abi.encodeWithSelector(SmokeFlopVault.SmokeMismatch.selector, "miner paid", 1_000e6, 40e6));
        smoker.smoke(pk, d);
    }

    /// Two smoke rounds on one deployment: the second still pays exactly once and does not inherit the first's escrow.
    function test_smokeTwiceOnSameDeployment() public {
        vm.chainId(RHC_TESTNET);
        FlopVaultDeployment.Deployment memory d = deployer.deploy(pk);
        smoker.smoke(pk, d);
        SmokeFlopVault.Result memory r = smoker.smoke(pk, d);
        assertEq(r.channelId, 2);
        assertEq(TestToken(d.tUSDC).balanceOf(d.miner), 80e6);
    }
}
