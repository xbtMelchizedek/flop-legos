// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlopVault} from "../../src/FlopVault.sol";
import {MockComputeStrategy} from "../../src/mocks/MockComputeStrategy.sol";
import {DeployHyperEVM} from "../../script/DeployHyperEVM.s.sol";

interface IWHYPE {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Runs only when HYPEREVM_FORK_URL is set (e.g. a local anvil forked from the official testnet RPC).
/// Deploys with the real script on the fork, then round-trips WHYPE through the vault. No live transactions.
contract HyperEVMForkTest is Test {
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    bool forked;
    FlopVault vault;
    MockComputeStrategy strategy;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("HYPEREVM_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
        vm.setEnv("DEPLOYER_ADDR", vm.toString(deployer));
        (vault, strategy) = new DeployHyperEVM().run();
    }

    function test_fork_wiring() public view {
        if (!forked) return;
        assertEq(block.chainid, 998);
        assertEq(vault.asset(), WHYPE);
        assertEq(strategy.vault(), address(vault));
        assertEq(vault.owner(), deployer);
        assertEq(vault.keeper(), deployer);
        assertEq(vault.guardian(), deployer);
        assertEq(vault.depositCap(), 100e18);
        assertEq(vault.symbol(), "fvFLOP");
        assertEq(vault.decimals(), 24);
    }

    function test_fork_whype_round_trip() public {
        if (!forked) return;
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        IWHYPE(WHYPE).deposit{value: 5 ether}();
        IWHYPE(WHYPE).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(5 ether, alice);
        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 5 ether);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertEq(out, 5 ether - 0, "full redeem returns the deposit (rounding favors the vault by < 1 wei)");
        assertEq(IWHYPE(WHYPE).balanceOf(alice), 5 ether);
        assertEq(vault.totalSupply(), 0);
    }

    function test_fork_cap_holds() public {
        if (!forked) return;
        vm.deal(alice, 200 ether);
        vm.startPrank(alice);
        IWHYPE(WHYPE).deposit{value: 101 ether}();
        IWHYPE(WHYPE).approve(address(vault), type(uint256).max);
        vm.expectRevert(FlopVault.ExceedsMaxDeposit.selector);
        vault.deposit(101 ether, alice);
        vm.stopPrank();
    }

    function test_fork_script_refuses_other_chains() public {
        if (!forked) return;
        vm.chainId(999);
        DeployHyperEVM s = new DeployHyperEVM();
        vm.expectRevert(abi.encodeWithSelector(DeployHyperEVM.WrongChain.selector, 999));
        s.run();
    }
}
