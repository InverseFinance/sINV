// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {sINV} from "src/sInv.sol";
import {sInvHelper} from "src/sInvHelper.sol";
import {Test, console2} from "forge-std/Test.sol";
import {MockMarket} from "test/mocks/MockMarket.sol";
import {MockEscrow} from "test/mocks/MockEscrow.sol";
import {Mintable} from "test/Mintable.sol";

contract sINVTest is Test {

    Mintable inv;
    Mintable dbr;
    MockMarket invMarket;
    MockEscrow invEscrow;
    sINV sInv;
    sInvHelper helper;
    address gov;
    address user = address(0xA);
    uint K = 10 ** 36;
    
    function setUp() public{
        inv = new Mintable("Inverse Token", "INV");
        dbr = new Mintable("Inv Borrowing Rights", "DBR");
        invMarket = new MockMarket(address(dbr), address(inv));
        sInv = new sINV(address(inv), address(invMarket), gov, K);
        invEscrow = MockEscrow(address(sInv.invEscrow()));
        helper = new sInvHelper(address(sInv));
    }

    function testDeposit() external {
        uint amount = 10 ** 18;
        inv.mint(user, amount);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), 0, "user balance");
        assertEq(sInv.totalAssets(), amount, "sInv totalAssets");
        assertEq(inv.balanceOf(address(sInv.invEscrow())), amount, "escrow inv balance");
    }

    function testDeposit_withMinBalance() external {
        uint amount = 10 ** 18;
        inv.mint(user, 2 * amount);
        vm.startPrank(gov);
        sInv.setMinBuffer(10 ** 18);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), amount, "User balance not equal amount after first deposit");
        assertEq(sInv.totalAssets(), amount, "sInv totalAssets not equal amount after first deposit");
        assertEq(inv.balanceOf(address(sInv.invEscrow())), 0);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), 0, "User balance not equal 0 after second deposit");
        assertEq(sInv.totalAssets(), 2 * amount, "sInv totalAssets not equal 2 x amount after second deposit");
        assertEq(inv.balanceOf(address(sInv.invEscrow())), amount);
    }

    function testDeposit_fail_createBelowMinShares() external {
         uint amount = 10 ** 15;
        inv.mint(user, amount);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        vm.expectRevert(
            sINV.BelowMinShares.selector
        );
        sInv.deposit(amount, user);
        vm.stopPrank();
    }

    function testWithdraw() external {
        uint amount = 10 * 10 ** 18;
        inv.mint(user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.startPrank(user);
        sInv.withdraw(amount - sInv.MIN_SHARES(), user, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), amount - sInv.MIN_SHARES());
        assertEq(sInv.totalAssets(), sInv.MIN_SHARES());
        assertEq(inv.balanceOf(address(sInv.invEscrow())), sInv.MIN_SHARES());
    }

    function testWithdraw_TimePassWithNoRevenue() external {
        uint amount = 10 * 10 ** 18;
        inv.mint(user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.warp(block.timestamp + 2 weeks);
        vm.stopPrank();

        vm.startPrank(user);
        sInv.withdraw(amount - sInv.MIN_SHARES(), user, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), amount - sInv.MIN_SHARES());
        assertGt(sInv.totalAssets(), sInv.MIN_SHARES());
        assertGt(inv.balanceOf(address(sInv.invEscrow())), sInv.MIN_SHARES());
    }

    function testWithdraw_fail_belowMinShares() external {
        uint amount = 10 ** 18;
        inv.mint(user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.startPrank(user);
        uint minShares = sInv.MIN_SHARES();
        vm.expectRevert(
            sINV.BelowMinShares.selector
        );
        sInv.withdraw(amount + 1 - minShares, user, user);
        vm.stopPrank();
    }

    function testWithdraw_fail_belowMinAssets() external {
        uint amount = 10 ** 18;
        inv.mint(user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(
            sINV.InsufficientAssets.selector
        );
        sInv.withdraw(amount, user, user);
    }

    function test_buyDBRSingle() public {
        vm.warp(7 days); // for totalAssets()
        dbr.mint(address(sInv), 1e18);
        uint exactInvIn = 1 ether;
        uint exactDbrOut = helper.getDbrOut(exactInvIn);
        inv.mint(address(this), exactInvIn);
        inv.approve(address(sInv), exactInvIn);
        uint newDbrReserve = sInv.getDbrReserve() - exactDbrOut;
        uint dbrClaimableBefore = invEscrow.claimable();
        uint dbrBalBefore = dbr.balanceOf(address(sInv));
        sInv.buyDBR(exactInvIn, exactDbrOut, address(1));
        if(dbrBalBefore >= exactDbrOut){
            assertEq(invEscrow.claimable(), dbrClaimableBefore, "No claims made if enough tokens to pay for transfer");
        } else {
            assertEq(invEscrow.claimable(), 0, "Not all DBR claimed");
        }
        assertEq(inv.balanceOf(address(this)), 0, "inv balance");
        assertEq(dbr.balanceOf(address(1)), exactDbrOut, "dbr balance");
        assertEq(sInv.getDbrReserve(), newDbrReserve, "dbr reserve");
        assertEq(sInv.getInvReserve(), sInv.getK() / newDbrReserve, "inv reserve");
        assertEq(sInv.periodRevenue(), exactInvIn, "period revenue");
        assertEq(sInv.totalAssets(), 0, "total assets 0 days");
        vm.warp(14 days);
        assertEq(sInv.totalAssets(), 0, "total assets 14 days");
        vm.warp(14 days + (7 days / 4));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 16.25 days");
        vm.warp(14 days + (7 days / 2));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 17.5 days");
        vm.warp(21 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
        vm.warp(21 days + 1);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 22 days");
        vm.warp(28 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 28 days");
    }

    function test_buyDBR(uint exactInvIn) public {
        vm.warp(7 days); // for totalAssets()
        dbr.mint(address(sInv), 1e18);
        exactInvIn = bound(exactInvIn, 1, sInv.MAX_ASSETS());
        uint exactDbrOut = helper.getDbrOut(exactInvIn);
        inv.mint(address(this), exactInvIn);
        inv.approve(address(sInv), exactInvIn);
        uint newDbrReserve = sInv.getDbrReserve() - exactDbrOut;
        sInv.buyDBR(exactInvIn, exactDbrOut, address(1));
        assertEq(inv.balanceOf(address(this)), 0, "inv balance");
        assertEq(dbr.balanceOf(address(1)), exactDbrOut, "dbr balance");
        assertEq(sInv.getDbrReserve(), newDbrReserve, "dbr reserve");
        assertEq(sInv.getInvReserve(), sInv.getK() / newDbrReserve, "inv reserve");
        assertEq(sInv.periodRevenue(), exactInvIn, "period revenue");
        assertEq(sInv.totalAssets(), 0, "total assets");
        vm.warp(14 days);
        assertEq(sInv.totalAssets(), 0, "total assets 14 days");
        vm.warp(14 days + (7 days / 4));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 16.25 days");
        vm.warp(14 days + (7 days / 2));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 17.5 days");
        vm.warp(21 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
        vm.warp(21 days + 1);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 22 days");
        vm.warp(28 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 28 days");
    }

    function test_buyDBR(uint exactInvIn, uint exactDbrOut) public {
        vm.warp(7 days); // for totalAssets()
        dbr.mint(address(sInv), 1e18);
        exactInvIn = bound(exactInvIn, 1, sInv.MAX_ASSETS());
        exactDbrOut = bound(exactDbrOut, 0, 1e18);
        inv.mint(address(this), exactInvIn);
        inv.approve(address(sInv), exactInvIn);
        uint _K = sInv.getK();
        uint newDbrReserve = sInv.getDbrReserve() - exactDbrOut;
        uint newInvReserve = sInv.getInvReserve() + exactInvIn;
        uint newK = newInvReserve * newDbrReserve;
        if(newK < _K) {
            vm.expectRevert(
                sINV.Invariant.selector
            );
            sInv.buyDBR(exactInvIn, exactDbrOut, address(1));
        } else {
            sInv.buyDBR(exactInvIn, exactDbrOut, address(1));
            assertEq(inv.balanceOf(address(this)), 0, "inv balance");
            //assertEq(savings.balanceOf(address(sInv)), exactInvIn, "savings balance");
            assertEq(dbr.balanceOf(address(1)), exactDbrOut, "dbr balance");
            assertEq(sInv.getDbrReserve(), newDbrReserve, "dbr reserve");
            assertEq(sInv.getInvReserve(), sInv.getK() / newDbrReserve, "inv reserve");
            assertEq(sInv.periodRevenue(), exactInvIn, "period revenue");
            assertEq(sInv.totalAssets(), 0, "total assets");
            vm.warp(14 days);
            assertEq(sInv.totalAssets(), 0, "total assets 14 days");
            vm.warp(14 days + (7 days / 4));
            if(exactInvIn > sInv.MAX_ASSETS()) exactInvIn = sInv.MAX_ASSETS();
            assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 16.25 days");
            vm.warp(14 days + (7 days / 2));
            assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 17.5 days");
            vm.warp(21 days);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
            vm.warp(21 days + 1);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 22 days");
            vm.warp(28 days);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 28 days");
        }
    }

    function test_getK() public {
        vm.warp(7 days);
        assertEq(sInv.getK(), K);
        vm.prank(gov);
        sInv.setTargetK(3 * K);
        assertEq(sInv.getK(), K);
        vm.warp(10.5 days);
        assertEq(sInv.getK(), 2 * K);
        vm.warp(14 days);
        assertEq(sInv.getK(), 3 * K);
        vm.warp(21 days);
        assertEq(sInv.getK(), 3 * K);
    }

    function test_totalAssets(uint amount) public {
        //vm.warp(7 days); // for totalAssets()
        amount = bound(amount, sInv.convertToAssets(sInv.MIN_SHARES()), sInv.MAX_ASSETS());
        assertEq(sInv.totalAssets(), 0);
        inv.mint(address(this), amount);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, address(this));
        assertEq(sInv.totalAssets(), amount);
    }


    // GOV GATED FUNCTIONS //

    function testSetTargetK() external {
        vm.expectRevert(
            abi.encodeWithSelector(sINV.OnlyGov.selector)
        );
        sInv.setTargetK(1e40);

        assertEq(sInv.targetK(), K, "Target K not equal constructor supplied K");
        assertEq(sInv.lastKUpdate(), 0, "LastKUpdate not equal 0");
        vm.prank(gov);
        sInv.setTargetK(1e40);
        assertEq(sInv.targetK(), 1e40, "Target K not equal new target K");
        assertEq(sInv.prevK(), K, "Previous K not equal constructor supplied K");
        assertEq(sInv.lastKUpdate(), block.timestamp, "lastKUpdate not equal block timestamp");
    }

    function testSetMinBuffer() external {
        vm.expectRevert(
            abi.encodeWithSelector(sINV.OnlyGov.selector)
        );
        sInv.setMinBuffer(1);

        assertEq(sInv.minBuffer(), 0);
        vm.prank(gov);
        sInv.setMinBuffer(1);
        assertEq(sInv.minBuffer(), 1);
    }

    function testSetPeriod() external {
        vm.expectRevert(
            abi.encodeWithSelector(sINV.OnlyGov.selector)
        );
        sInv.setPeriod(1 days);

        assertEq(sInv.period(), 7 days);
        vm.prank(gov);
        sInv.setPeriod(1 days);
        assertEq(sInv.period(), 1 days);
    }

    /// AUTH ///

    function testSetPendingGov() external {
        vm.expectRevert(
            abi.encodeWithSelector(sINV.OnlyGov.selector)
        );
        sInv.setPendingGov(user);

        assertEq(sInv.pendingGov(), address(0));
        vm.prank(gov);
        sInv.setPendingGov(user);
        assertEq(sInv.pendingGov(), user);
    }

    function testAcceptPendingGov() external {
        vm.expectRevert(
            abi.encodeWithSelector(sINV.OnlyPendingGov.selector)
        );
        sInv.acceptGov();
        vm.prank(gov);
        sInv.setPendingGov(user);

        assertEq(sInv.gov(), gov);
        vm.prank(user);
        sInv.acceptGov();
        assertEq(sInv.gov(), user);
    }
}
