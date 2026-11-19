// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../../src/mocks/TestToken.sol";
import {Owned2Step} from "../../src/Owned2Step.sol";

contract TestTokenTest is Test {
    TestToken internal token;
    address internal owner = makeAddr("owner");
    address internal endpoint = makeAddr("endpoint");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant CAP = 1_000_000e6;

    function setUp() public {
        token = new TestToken("TEST tUSDC (testnet mock, no value)", "tUSDC-TEST", 6, CAP, owner);
        vm.prank(owner);
        token.setEndpoint(endpoint, true);
    }

    function test_metadataIsExact() public view {
        assertEq(token.name(), "TEST tUSDC (testnet mock, no value)");
        assertEq(token.symbol(), "tUSDC-TEST");
        assertEq(token.decimals(), 6);
        assertEq(token.mintCapPerCall(), CAP);
    }

    function test_anyoneMintsUpToCap() public {
        vm.prank(alice);
        token.mint(alice, CAP);
        assertEq(token.balanceOf(alice), CAP);
    }

    function test_mintAboveCapReverts() public {
        vm.expectRevert(TestToken.MintAboveCap.selector);
        token.mint(alice, CAP + 1);
    }

    function test_walletToWalletTransferReverts() public {
        token.mint(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(TestToken.NotTradable.selector);
        token.transfer(bob, 1e6);
    }

    /// An approval does not open a side door: transferFrom between two wallets is still refused.
    function test_walletToWalletTransferFromReverts() public {
        token.mint(alice, 1e6);
        vm.prank(alice);
        token.approve(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(TestToken.NotTradable.selector);
        token.transferFrom(alice, bob, 1e6);
    }

    function test_transfersToAndFromEndpointPass() public {
        token.mint(alice, 1e6);
        vm.prank(alice);
        token.transfer(endpoint, 1e6);
        vm.prank(endpoint);
        token.transfer(bob, 1e6);
        assertEq(token.balanceOf(bob), 1e6);
    }

    function test_revokedEndpointStopsRouting() public {
        token.mint(endpoint, 1e6);
        vm.prank(owner);
        token.setEndpoint(endpoint, false);
        vm.prank(endpoint);
        vm.expectRevert(TestToken.NotTradable.selector);
        token.transfer(bob, 1e6);
    }

    function test_onlyOwnerSetsEndpoint() public {
        vm.prank(alice);
        vm.expectRevert(Owned2Step.NotOwner.selector);
        token.setEndpoint(alice, true);
    }

    /// Property: a transfer succeeds iff one side is an allowlisted endpoint.
    function testFuzz_transferNeedsAnEndpointSide(address from, address to, bool fromIsEndpoint, bool toIsEndpoint)
        public
    {
        vm.assume(from != address(0) && to != address(0) && from != to);
        vm.startPrank(owner);
        token.setEndpoint(from, fromIsEndpoint);
        token.setEndpoint(to, toIsEndpoint);
        vm.stopPrank();
        token.mint(from, 1);
        vm.prank(from);
        if (!fromIsEndpoint && !toIsEndpoint) vm.expectRevert(TestToken.NotTradable.selector);
        token.transfer(to, 1);
    }
}
