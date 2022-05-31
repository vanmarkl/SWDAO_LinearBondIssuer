// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/LinearBondIssuer.sol";

// Fake CustomBalancerPool contract
contract FakePool {
	function getValue() external pure returns (uint, uint) {
		return (1e18, 10e18);
	}
	function transferFrom(address, address, uint) external pure returns (bool) {
		return true;
	}
}

contract ContractTest is Test {
	IERC20 constant SWD = IERC20(0xaeE24d5296444c007a532696aaDa9dE5cE6caFD0);

	LinearBondIssuer private issuer;

	function setUp() public {
		FakePool fakePool = new FakePool();
		vm.etch(0x24Ec3C300Ff53b96937c39b686844dB9E471421e, address(fakePool).code);
		delete fakePool;
		issuer = new LinearBondIssuer(5, 25);
		deal(address(SWD), address(this), 500000e18);
		SWD.approve(address(issuer), 500000e18);
		issuer.addBalance(500000e18);
	}

	function test_stake(address a, uint88 x) public {
		bool outOfRange = 
			x / 10 > 476190476190476190476190 ||
			((uint(x) / 10) * 105) / 100 < 104 weeks;
		vm.startPrank(a, a);
		if (outOfRange)
			vm.expectRevert(getSelector("NotAvailable()"));
		issuer.stake(x);
		vm.stopPrank();
		assertEq(issuer.balanceAvailable(a), 0);
		assertEq(issuer.balanceAvailableFuture(address(this)), 0);
		if (outOfRange) {
			assertEq(issuer.balanceAvailableFuture(a), 0);
			return;
		} else {
			assertApproxEqRel(
				issuer.balanceAvailableFuture(a),
				(uint(x) * 105) / 1000,
				1e15
			);
		}
		vm.warp(block.timestamp + 26 weeks);
		uint availableLast = issuer.balanceAvailable(a);
		assertTrue(availableLast > 0);
		vm.warp(block.timestamp + 52 weeks);
		assertTrue(issuer.balanceAvailable(a) > availableLast);
		availableLast = issuer.balanceAvailable(a);
		vm.warp(block.timestamp + 26 weeks - 1);
		assertTrue(issuer.balanceAvailable(a) > availableLast);
		assertTrue(issuer.balanceAvailable(a) < issuer.balanceAvailableFuture(a));
		vm.warp(block.timestamp + 1);
		assertEq(
			issuer.balanceAvailable(a),
			issuer.balanceAvailableFuture(a)
		);
	}

	function test_stakeForRemaining(address a, uint96 x) public {
		x = uint96(bound(x, 1e18, 4000000e18));
		vm.prank(a, a);
		issuer.stake(x);
		(uint80 balanceRemaining,,,,) = issuer.slot0();
		assertEq(balanceRemaining, 500000e18 - issuer.balanceAvailableFuture(a));
		vm.prank(a, a);
		issuer.stakeForRemaining();
		assertEq(issuer.balanceAvailableFuture(a), 500000e18);
		(balanceRemaining,,,,) = issuer.slot0();
		assertEq(balanceRemaining, 0);
	}

	function test_withdraw(address a, uint96 x) public {
		vm.assume(!(a == address(0) || a == address(issuer)));
		x = uint96(bound(x, 1e18, 4000000e18));
		vm.startPrank(a, a);
		issuer.stake(x);
		vm.expectRevert(getSelector("NotAvailable()"));
		issuer.withdraw();
		uint availableFuture = issuer.balanceAvailableFuture(a);
		vm.warp(block.timestamp + 104 weeks);
		issuer.withdraw();
		assertEq(issuer.balanceAvailableFuture(a), 0);
		assertEq(SWD.balanceOf(a), availableFuture);
		assertEq(SWD.balanceOf(address(issuer)), 500000e18 - availableFuture);
		issuer.stakeForRemaining();
		vm.expectRevert(getSelector("NotAvailable()"));
		issuer.withdraw();
		vm.warp(block.timestamp + 104 weeks);
		issuer.withdraw();
		vm.stopPrank();
		assertEq(issuer.balanceAvailableFuture(a), 0);
		assertEq(SWD.balanceOf(a), 500000e18);
		assertEq(SWD.balanceOf(address(issuer)), 0);
	}

	function test_addBalance(uint16 x) public {
		deal(address(SWD), address(this), uint(x) * 1e18);
		SWD.approve(address(issuer), uint(x) * 1e18);
		if (x == 0)
			vm.expectRevert(getSelector("NotAvailable()"));
		issuer.addBalance(uint80(x)*1e18);
		(uint80 balanceRemaining,,,,) = issuer.slot0();
		assertEq(balanceRemaining, (500000 + uint(x)) * 1e18);
		assertEq(SWD.balanceOf(address(issuer)), balanceRemaining);
	}

	function test_setBonus(address a, uint8 x, uint8 y) public {
		vm.assume(!(a == address(0) || a == address(issuer) || a == address(this)));
		x = uint8(bound(x, 0, 254));
		y = uint8(bound(y, x + 1, 255));
		issuer.setBonus(x, y);
		(, uint8 min, uint8 max,,) = issuer.slot0();
		assertEq(min, x);
		assertEq(max, y);
		vm.startPrank(a, a);
		issuer.stake(1000000e17);
		uint availableLast01 = issuer.balanceAvailableFuture(a);
		assertEq(availableLast01, (100000e17 * (100 + uint(min))) / 100);
		vm.warp(block.timestamp + 4 weeks);
		issuer.stake(1000000e17);
		uint availableLast02 = issuer.balanceAvailableFuture(a);
		assertApproxEqRel(
			availableLast02,
			availableLast01 + ((100000e17 * (100 + ((uint(min) + uint(max)) / 2))) / 100),
			1e16
		);
		vm.warp(block.timestamp + 8 weeks);
		issuer.stake(1000000e17);
		vm.stopPrank();
		availableLast01 = issuer.balanceAvailableFuture(a);
		assertEq(availableLast01, availableLast02 + ((100000e17 * (100 + uint(max))) / 100));
	}

	function test_ownerTransfer(address a, bool b) public {
		vm.assume(a != address(this));
		issuer.ownerTransfer(a);
		vm.startPrank(a, a);
		if (b) {
			vm.warp(block.timestamp + 37 hours);
			vm.expectRevert(getSelector("TimerExpired()"));
			issuer.ownerConfirm();
		} else {
			issuer.ownerConfirm();
			issuer.ownerTransfer(address(this));
			vm.stopPrank();
			vm.expectRevert(getSelector("Unauthorized()"));
			issuer.setBonus(10, 100);
			issuer.ownerConfirm();
		}
	}

	function test_withdrawToken(address a, uint96 x) public {
		vm.assume(!(a == address(0) || a == address(issuer) || a == address(this)));
		x = uint96(bound(x, 1e18, 4000000e18));
		vm.prank(a, a);
		issuer.stake(x);
		issuer.withdrawToken(SWD);
		uint availableFuture = issuer.balanceAvailableFuture(a);
		vm.warp(block.timestamp + 104 weeks);
		vm.prank(a, a);
		issuer.withdraw();
		assertEq(SWD.balanceOf(address(issuer)), 0);
		assertEq(SWD.balanceOf(a), availableFuture);
		assertEq(SWD.balanceOf(address(this)), 500000e18 - availableFuture);
	}

	function getSelector(string memory _data) private pure returns (bytes4) {
		return bytes4(keccak256(bytes(_data)));
	}
}
