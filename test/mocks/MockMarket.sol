pragma solidity ^0.8.21;

import {MockEscrow} from "test/mocks/MockEscrow.sol";
interface IERC20 {
    function transferFrom(address, address, uint) external;
}
contract MockMarket {

    address public dbr;
    address public collateral;
    MockEscrow escrow;
    
    constructor(address _dbr, address _collateral) {
        dbr = _dbr;
        collateral = _collateral;
    }
    
    function predictEscrow(address escrowOwner) external returns(address) {
        if(address(escrow) == address(0)){
            escrow = new MockEscrow(escrowOwner, collateral, dbr);
        }
        return address(escrow);
    }

    function withdraw(uint amount) external {
        require(escrow.beneficiary() == msg.sender);
        escrow.pay(msg.sender, amount);
    }

    function deposit(uint amount) external {
        if(address(escrow) == address(0)){
            escrow = new MockEscrow(msg.sender, collateral, dbr);
        }
        IERC20(collateral).transferFrom(msg.sender, address(escrow), amount);
    }
            

}
