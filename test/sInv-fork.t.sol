// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {sINV} from "src/sInv.sol";
import {sInvHelper} from "src/sInvHelper.sol";
import {Test, console2} from "forge-std/Test.sol";
import {Mintable} from "test/Mintable.sol";

interface IInvEscrow {
    function onDeposit() external;
    function balance() external view returns (uint);
    function claimDBR() external;
    function claimable() external view returns (uint);
    function DBR() external view returns (address);
}

interface IMarket {
    function deposit(uint amount) external;
    function withdraw(uint amount) external;
    function dbr() external returns (address);
    function collateral() external returns (address);
    function predictEscrow(address user) external returns (address);
}

interface IMintable {
    function mint(address to, uint amount) external;
    function addMinter(address minter) external;
}


contract sINVForkTest is Test {

    Mintable inv = Mintable(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);
    Mintable xinv = Mintable(0x1637e4e9941D55703a7A5E7807d6aDA3f7DCD61B);
    Mintable dbr = Mintable(0xAD038Eb671c44b853887A7E32528FaB35dC5D710);
    IMarket invMarket = IMarket(0xb516247596Ca36bf32876199FBdCaD6B3322330B);
    IInvEscrow invEscrow;
    sINV sInv;
    sInvHelper helper;
    address gov = address(0x926dF14a23BE491164dCF93f4c468A50ef659D5B);
    address user = address(0xA);
    uint K = 10 ** 36;
    
    function setUp() public{
        string memory url = vm.rpcUrl("mainnet");
        vm.createSelectFork(url);
        sInv = new sINV(address(inv), address(invMarket), gov, K);
        invEscrow = IInvEscrow(invMarket.predictEscrow(address(sInv)));
        helper = new sInvHelper(address(sInv));
        vm.prank(gov);
        IMintable(address(dbr)).addMinter(address(this));
    }

    function testDeposit() external {
        uint amount = 10 ** 18;
        deal(address(inv), user, amount);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), 0, "user balance");
        assertApproxEqAbs(sInv.totalAssets(), amount, 10, "sInv totalAssets");
        if(amount < sInv.minBuffer()){
            assertEq(inv.balanceOf(address(sInv)), amount, "sInv inv balance");
        } else {
            assert(address(sInv.invEscrow()) != address(0));
            assertGt(xinv.balanceOf(address(sInv.invEscrow())), 0, "escrow xinv balance");
        }
    }

    function testDeposit_withMinBalance() external {
        uint amount = 10 ** 18;
        deal(address(inv), user, 2 * amount);
        vm.startPrank(gov);
        sInv.setMinBuffer(10 ** 18);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), amount, "User balance not equal amount after first deposit");
        assertEq(sInv.totalAssets(), amount, "sInv totalAssets not equal amount after first deposit");
        assertEq(xinv.balanceOf(address(sInv.invEscrow())), 0);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        assertEq(inv.balanceOf(user), 0, "User balance not equal 0 after second deposit");
        assertApproxEqAbs(sInv.totalAssets(), 2 * amount, 10, "sInv totalAssets not equal 2 x amount after second deposit");
        assertGt(xinv.balanceOf(address(sInv.invEscrow())), 0);
    }

    function testDeposit_fail_createBelowMinShares() external {
        uint amount = 10 ** 15;
        deal(address(inv), user, amount);

        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        vm.expectRevert("Shares below MIN_SHARES");
        sInv.deposit(amount, user);
        vm.stopPrank();
    }

    function testRedeem() external {
        uint amount = 10 * 10 ** 18;
        deal(address(inv), user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.startPrank(user);
        sInv.redeem(sInv.balanceOf(user) - sInv.MIN_SHARES(), user, user);
        vm.stopPrank();

        assertApproxEqAbs(inv.balanceOf(user), amount - sInv.MIN_SHARES(), 10, "inv user balance");
        assertApproxEqAbs(sInv.totalAssets(), sInv.MIN_SHARES(), 10, "sInv totalAssets");
        assertGt(xinv.balanceOf(address(sInv.invEscrow())), 0);
    }

    function testRedeem_TimePassWithNoRevenue() external {
        uint amount = 10 * 10 ** 18;
        deal(address(inv), user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.warp(block.timestamp + block.timestamp + 2 weeks);
        vm.stopPrank();

        vm.startPrank(user);
        sInv.redeem(sInv.balanceOf(address(user)) - sInv.MIN_SHARES(), user, user);
        vm.stopPrank();

        assertApproxEqAbs(inv.balanceOf(user), amount - sInv.MIN_SHARES(), 10, "inv user balance");
        assertGt(sInv.totalAssets(), sInv.MIN_SHARES(), "sInv totalAssets");
        assertGt(xinv.balanceOf(address(sInv.invEscrow())), 0);
    }

    function testWithdraw_fail_belowMinShares() external {
        uint amount = 10 ** 18;
        deal(address(inv), user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.startPrank(user);
        uint minShares = sInv.MIN_SHARES();
        vm.expectRevert("Shares below MIN_SHARES");
        sInv.withdraw(amount + 1 - minShares, user, user);
        vm.stopPrank();
    }

    function testWithdraw_fail_belowMinAssets() external {
        uint amount = 10 ** 18;
        deal(address(inv), user, amount);
        vm.startPrank(user);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, user);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert("Insufficient assets");
        sInv.withdraw(amount, user, user);
    }

    function test_buyDBRSingle() public {
        vm.prank(gov);
        uint nextPeriodStart = block.timestamp + sInv.period() - block.timestamp % sInv.period();
        vm.warp(nextPeriodStart);
        dbr.mint(address(sInv), 1e18);
        uint exactInvIn = 1 ether;
        uint exactDbrOut = helper.getDbrOut(exactInvIn);
        vm.prank(gov);
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
        //assertEq(savings.balanceOf(address(sInv)), exactInvIn, "savings balance");
        assertEq(dbr.balanceOf(address(1)), exactDbrOut, "dbr balance");
        assertEq(sInv.getDbrReserve(), newDbrReserve, "dbr reserve");
        assertEq(sInv.getInvReserve(), sInv.getK() / newDbrReserve, "inv reserve");
        assertEq(sInv.periodRevenue(), exactInvIn, "period revenue");
        assertEq(sInv.totalAssets(), 0, "total assets 0 days");
        vm.warp(nextPeriodStart + 3.5 days);
        assertEq(sInv.totalAssets(), 0, "total assets 3.5 days");
        vm.warp(nextPeriodStart + 7 days);
        assertEq(sInv.totalAssets(), 0, "total assets 7 days");
        vm.warp(nextPeriodStart + 7 days + (7 days / 4));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 8.25 days");
        vm.warp(nextPeriodStart + 7 days + (7 days / 2));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 10.5 days");
        vm.warp(nextPeriodStart + 14 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 14 days");
        vm.warp(nextPeriodStart + 15 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 15 days");
        vm.warp(nextPeriodStart + 21 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
    }

    function test_buyDBR(uint exactInvIn) public {
        uint nextPeriodStart = block.timestamp + sInv.period() - block.timestamp % sInv.period();
        vm.warp(nextPeriodStart);
        dbr.mint(address(sInv), 1e18);
        exactInvIn = bound(exactInvIn, 1, 2**96-1 - inv.totalSupply());
        uint exactDbrOut = helper.getDbrOut(exactInvIn);
        vm.prank(gov);
        inv.mint(address(this), exactInvIn);
        inv.approve(address(sInv), exactInvIn);
        uint newDbrReserve = sInv.getDbrReserve() - exactDbrOut;
        sInv.buyDBR(exactInvIn, exactDbrOut, address(1));
        assertEq(inv.balanceOf(address(this)), 0, "inv balance");
        //assertEq(savings.balanceOf(address(sInv)), exactInvIn, "savings balance");
        assertEq(dbr.balanceOf(address(1)), exactDbrOut, "dbr balance");
        assertEq(sInv.getDbrReserve(), newDbrReserve, "dbr reserve");
        assertEq(sInv.getInvReserve(), sInv.getK() / newDbrReserve, "inv reserve");
        assertEq(sInv.periodRevenue(), exactInvIn, "period revenue");
        assertEq(sInv.totalAssets(), 0, "total assets");
        vm.warp(nextPeriodStart + 7 days);
        assertEq(sInv.totalAssets(), 0, "total assets 7 days");
        vm.warp(nextPeriodStart + 7 days + (7 days / 4));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 8.25 days");
        vm.warp(nextPeriodStart + 7 days + (7 days / 2));
        assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 10.5 days");
        vm.warp(nextPeriodStart + 14 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 14 days");
        vm.warp(nextPeriodStart + 14 days + 1);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 15 days");
        vm.warp(nextPeriodStart + 21 days);
        assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
    }

    function test_buyDBR(uint exactInvIn, uint exactDbrOut) public {
        uint nextPeriodStart = block.timestamp + sInv.period() - block.timestamp % sInv.period();
        vm.warp(nextPeriodStart);
        dbr.mint(address(sInv), 1e18);
        exactInvIn = bound(exactInvIn, 1, 2**96-1 - inv.totalSupply());
        exactDbrOut = bound(exactDbrOut, 0, 1e18);
        vm.prank(gov);
        inv.mint(address(this), exactInvIn);
        inv.approve(address(sInv), exactInvIn);
        uint _K = sInv.getK();
        uint newDbrReserve = sInv.getDbrReserve() - exactDbrOut;
        uint newInvReserve = sInv.getInvReserve() + exactInvIn;
        uint newK = newInvReserve * newDbrReserve;
        if(newK < _K) {
            vm.expectRevert("Invariant");
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
            vm.warp(nextPeriodStart + 7 days);
            assertEq(sInv.totalAssets(), 0, "total assets 7 days");
            vm.warp(nextPeriodStart + 7 days + (7 days / 4));
            if(exactInvIn > sInv.MAX_ASSETS()) exactInvIn = sInv.MAX_ASSETS();
            assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 4, 20, "total assets 8.25 days");
            vm.warp(nextPeriodStart + 7 days + (7 days / 2));
            assertApproxEqAbs(sInv.totalAssets(), exactInvIn / 2, 20, "total assets 10.5 days");
            vm.warp(nextPeriodStart + 14 days);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 21 days");
            vm.warp(nextPeriodStart + 14 days + 1);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 14 days + 1");
            vm.warp(nextPeriodStart + 28 days);
            assertEq(sInv.totalAssets(), exactInvIn, "total assets 28 days");
        }
    }

    // function test_reapprove() public {
    //     vm.prank(address(sInv));
    //     inv.approve(address(invMarket), 0);
    //     assertEq(inv.allowance(address(sInv), address(invMarket)), 0);
    //     sInv.reapprove();
    //     assertEq(inv.allowance(address(sInv), address(invMarket)), 2**96-1);
    // }

    function test_getK() public {
        assertEq(sInv.getK(), K);
        vm.prank(gov);
        sInv.setTargetK(3 * K);
        assertEq(sInv.getK(), K, "not eq after 0 seconds");
        vm.warp(block.timestamp + 3.5 days);
        assertEq(sInv.getK(), 2 * K, "not 2 x after 3.5 days");
        vm.warp(block.timestamp + 7 days);
        assertEq(sInv.getK(), 3 * K);
        vm.warp(block.timestamp + 21 days);
        assertEq(sInv.getK(), 3 * K);
    }

    function test_totalAssets(uint amount) public {
        amount = bound(amount, sInv.convertToAssets(sInv.MIN_SHARES()), uint(2**96-1) - inv.totalSupply());
        assertEq(sInv.totalAssets(), 0);
        vm.prank(gov);
        inv.mint(address(this), amount);
        inv.approve(address(sInv), amount);
        sInv.deposit(amount, address(this));
        assertApproxEqAbs(sInv.totalAssets(), amount, 10, "sInv totalAssets");
    }


    // GOV GATED FUNCTIONS //

    function testSetTargetK() external {
        vm.expectRevert("ONLY GOV");
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
        vm.expectRevert("ONLY GOV");
        sInv.setMinBuffer(1);

        assertEq(sInv.minBuffer(), 0);
        vm.prank(gov);
        sInv.setMinBuffer(1);
        assertEq(sInv.minBuffer(), 1);
    }

    function testSetPeriod() external {
        vm.expectRevert("ONLY GOV");
        sInv.setPeriod(1 days);

        assertEq(sInv.period(), 7 days);
        vm.prank(gov);
        sInv.setPeriod(1 days);
        assertEq(sInv.period(), 1 days);
    }

    /// AUTH ///

    function testSetPendingGov() external {
        vm.expectRevert("ONLY GOV");
        sInv.setPendingGov(user);

        assertEq(sInv.pendingGov(), address(0));
        vm.prank(gov);
        sInv.setPendingGov(user);
        assertEq(sInv.pendingGov(), user);
    }

    function testAcceptPendingGov() external {
        vm.expectRevert("ONLY PENDINGGOV");
        sInv.acceptGov();
        vm.prank(gov);
        sInv.setPendingGov(user);

        assertEq(sInv.gov(), gov);
        vm.prank(user);
        sInv.acceptGov();
        assertEq(sInv.gov(), user);
    }
}
