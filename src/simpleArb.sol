pragma solidity ^0.8.21;

import {sINV} from "src/sInv.sol";

interface ICurvePool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) payable external returns(uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns(uint256);
}
interface IERC20 {
    function approve(address to, uint amount) external;
    function transfer(address to, uint amount) external;
    function balanceOf(address holder) external view returns(uint);
}

contract SimpleArb {
    ICurvePool public constant dbrTriPool = ICurvePool(0xC7DE47b9Ca2Fc753D6a2F167D8b3e19c6D18b19a);
    ICurvePool public constant invTriPool = ICurvePool(0x5426178799ee0a0181A89b4f57eFddfAb49941Ec);
    sINV public immutable sInv;
    IERC20 constant dbr = IERC20(0xAD038Eb671c44b853887A7E32528FaB35dC5D710);
    IERC20 constant inv = IERC20(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);
    IERC20 constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 constant wethIndex = 1;
    uint256 constant invIndex = 2; //Index 2 for both pools
    uint256 constant dbrIndex = 1;
    address owner;

    constructor(address _sInv){
        owner = msg.sender;
        sInv = sINV(_sInv);
        weth.approve(address(invTriPool), type(uint).max);
        inv.approve(address(invTriPool), type(uint).max);
        inv.approve(address(sInv), type(uint).max);
        dbr.approve(address(dbrTriPool), type(uint).max);
        weth.approve(address(invTriPool), type(uint).max);
    }

    function arb(uint amountWeth, uint expectedRevenue) external returns(uint wethOut){
        uint invIn = invTriPool.exchange(wethIndex, invIndex, amountWeth, 0);
        uint dbrOut = getDbrOut(invIn);
        sInv.buyDBR(invIn, dbrOut, address(this));
        uint invBal = dbrTriPool.exchange(dbrIndex, invIndex, dbrOut, 0);
        wethOut = invTriPool.exchange(invIndex, wethIndex, invBal, expectedRevenue);
    }
   
    function getRevenue(uint amountWeth) public view returns(int){
        uint invIn = invTriPool.get_dy(wethIndex, invIndex, amountWeth);
        uint dbrOut = getDbrOut(invIn);
        uint invBal = dbrTriPool.get_dy(dbrIndex, invIndex, dbrOut);
        uint wethOut = invTriPool.get_dy(invIndex, wethIndex, invBal);       
        return int(wethOut) - int(amountWeth);
    }

    function arbInv(uint invIn, uint expectedRevenue) external returns(uint invBal){
        uint dbrOut = getDbrOut(invIn);
        sInv.buyDBR(invIn, dbrOut, address(this));
        invBal = dbrTriPool.exchange(dbrIndex, invIndex, dbrOut, 0);
    }
    function getRevenueInv(uint invIn) public view returns(int){
        uint dbrOut = getDbrOut(invIn);
        uint invBal = dbrTriPool.get_dy(dbrIndex, invIndex, dbrOut);
        return int(invBal) - int(invIn);
    }

    function binaryRevenueSearch(uint minStep) external view returns (uint, int){
        uint amount = weth.balanceOf(address(this)) / 2; //Start binary search halfway. Max trade amount will be weth balance - minStep
        uint step = uint(amount) / 2;
        while(step > minStep){
            int inc = getRevenue(amount + step);
            int dec = getRevenue(amount - step);
            if(inc > dec) {
                amount += step;
            } else {
                amount -= step;
            }
            step /= 2;
        }
        return (amount, getRevenue(amount));
    }

    function wethToInv(uint amountWeth) external view returns(uint invOut) {
        invOut = invTriPool.get_dy(wethIndex, invIndex, amountWeth);
    }

    function getDbrOut(uint invIn) public view returns (uint dbrOut) {
        uint dbrReserve = sInv.getDbrReserve();
        uint invReserve = sInv.getInvReserve(dbrReserve);
        uint numerator = invIn * dbrReserve;
        uint denominator = invReserve + invIn;
        dbrOut = numerator / denominator;
    }
}

