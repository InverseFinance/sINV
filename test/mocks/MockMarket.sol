pragma solidity ^0.8.21;

import {MockEscrow} from "test/mocks/MockEscrow.sol";

contract MockMarket {

    address public dbr;
    address public collateral;
    MockEscrow escrow;
    
    constructor(address _dbr, address _collateral) {
        dbr = _dbr;
        collateral = _collateral;
    }
    
    function createEscrow(address escrowOwner) external returns(address) {
        escrow = new MockEscrow(escrowOwner, collateral, dbr);
        return address(escrow);
    }

    function withdraw(uint amount) external {
        require(escrow.beneficiary() == msg.sender);
        escrow.pay(msg.sender, amount);
    }

}
