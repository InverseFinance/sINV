// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {sINV, IERC20} from "src/sInv.sol";
import {sInvHelper} from "src/sInvHelper.sol";
import {SimpleArb, EmptyArb, ReentrantArb} from "src/simpleArb.sol";
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

interface IMintable is IERC20{
    function mint(address to, uint amount) external;
    function addMinter(address minter) external;
}


contract sINVArbForkTest is Test {

    Mintable inv = Mintable(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);
    Mintable xinv = Mintable(0x1637e4e9941D55703a7A5E7807d6aDA3f7DCD61B);
    Mintable dbr = Mintable(0xAD038Eb671c44b853887A7E32528FaB35dC5D710);
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IMarket invMarket = IMarket(0xb516247596Ca36bf32876199FBdCaD6B3322330B);
    IInvEscrow invEscrow;
    sINV sInv;
    SimpleArb simpleArb;
    sInvHelper helper;
    address gov = address(0x926dF14a23BE491164dCF93f4c468A50ef659D5B);
    address user = address(0xA);
    uint K = 10 ** 40;
    
    function setUp() public{
        string memory url = vm.rpcUrl("mainnet");
        vm.createSelectFork(url);
        sInv = new sINV(address(inv), address(invMarket), gov, K);
        simpleArb = new SimpleArb(address(sInv));
        invEscrow = IInvEscrow(invMarket.predictEscrow(address(sInv)));
        helper = new sInvHelper(address(sInv));
        vm.prank(gov);
        IMintable(address(dbr)).addMinter(address(this));
    }

    function test_arb() public {
        vm.prank(gov);
        dbr.mint(address(sInv), 1e21 * 5);
        vm.prank(gov);
        deal(address(weth), address(simpleArb), 1 ether);
        int expectedRevenue = simpleArb.getRevenue(0.02 ether);
        uint initialBal = weth.balanceOf(address(simpleArb));
        console2.log("Expected revenue:", expectedRevenue);
        simpleArb.arb(0.02 ether, uint(expectedRevenue) * 9 / 10);
        console2.log("Actual revenue:", weth.balanceOf(address(simpleArb)) - initialBal);
    }

    function test_flashArb() public {
        vm.prank(gov);
        dbr.mint(address(sInv), 1e21 * 5);
        vm.prank(gov);
        deal(address(weth), address(simpleArb), 1 ether);
        int expectedRevenue = simpleArb.getRevenue(0.02 ether);
        uint initialBal = weth.balanceOf(address(simpleArb));
        console2.log("Expected revenue:", expectedRevenue);
        uint invIn = simpleArb.wethToInv(0.02 ether);
        simpleArb.flashArb(invIn, uint(expectedRevenue) * 9 / 10);
        console2.log("Actual revenue:", weth.balanceOf(address(simpleArb)) - initialBal);
    }

    function test_arbInv() public {
        vm.prank(gov);
        dbr.mint(address(sInv), 1e21 * 5);
        uint exactInvIn = 2 ether;
        vm.prank(gov);
        inv.mint(address(simpleArb), exactInvIn);
        int expectedRevenue = simpleArb.getRevenueInv(exactInvIn);
        uint initialBal = inv.balanceOf(address(simpleArb));
        console2.log("Expected revenue:", expectedRevenue);
        simpleArb.arbInv(exactInvIn, uint(expectedRevenue) * 9 / 10);
        console2.log("Actual revenue:", inv.balanceOf(address(simpleArb)) - initialBal);
    }

    function test_flashArbInv() public {
        vm.prank(gov);
        dbr.mint(address(sInv), 1e21 * 5);
        uint exactInvIn = 2 ether;
        vm.prank(gov);
        inv.mint(address(simpleArb), exactInvIn);
        int expectedRevenue = simpleArb.getRevenueInv(exactInvIn);
        uint initialBal = inv.balanceOf(address(simpleArb));
        console2.log("Expected revenue:", expectedRevenue);
        simpleArb.flashArbInv(exactInvIn, uint(expectedRevenue) * 9 / 10);
        console2.log("Actual revenue:", inv.balanceOf(address(simpleArb)) - initialBal);
    }

    function test_flashArb_fails_noRepayment() public {
        EmptyArb evilArb = new EmptyArb(address(sInv));
        vm.prank(gov);
        dbr.mint(address(sInv), 1e21 * 5);
        vm.prank(gov);
        deal(address(weth), address(evilArb), 1 ether);
        int expectedRevenue = evilArb.getRevenue(0.02 ether);
        uint invIn = evilArb.wethToInv(0.02 ether);
        vm.expectRevert();
        evilArb.flashArb(invIn, uint(expectedRevenue) * 9 / 10);
    }

    function test_flashArb_fails_reentrantPurchase() public {
        ReentrantArb reentrantArb = new ReentrantArb(address(sInv));
        dbr.mint(address(sInv), 1e21 * 5);
        uint exactInvIn = 1 ether;
        vm.prank(gov);
        inv.mint(address(reentrantArb), exactInvIn);
        int expectedRevenue = reentrantArb.getRevenueInv(exactInvIn);
        uint initialBal = inv.balanceOf(address(reentrantArb));
        console2.log("Initial bal:", initialBal);
        vm.expectRevert("Invariant");
        reentrantArb.flashArbInv(exactInvIn, uint(expectedRevenue) * 9 / 10);
        console2.log("Inverse bal after:", inv.balanceOf(address(reentrantArb)));
    }
}
