pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

interface IMintable is IERC20{
    function mint(address, uint) external;
}


contract MockEscrow {
    address public beneficiary;
    IMintable public asset;
    IMintable public dbr;
    uint creation;
    uint lastClaim;
    uint lastPay;
    uint claimed;
    uint paid;

    constructor(address _beneficiary, address _asset, address _dbr){
        beneficiary = _beneficiary;
        asset = IMintable(_asset);
        dbr = IMintable(_dbr);
        lastClaim = block.timestamp;
        lastPay = block.timestamp;
    }

    function pay(address receiver, uint amount) external {
        uint assetBal = asset.balanceOf(address(this));
        if(assetBal < balance()) asset.mint(address(this), balance() - assetBal);
        lastPay = block.timestamp;
        asset.transfer(receiver, amount);
    }

    function balance() public view returns(uint) {
        uint assetBal = asset.balanceOf(address(this));
        if(block.timestamp - lastPay > 0) return assetBal * (block.timestamp - lastPay);
        return assetBal;
    }

    function claimable() public view returns(uint) {
        return (block.timestamp - lastClaim) * balance() / 100;
    }

    function claimDBR() external {
        dbr.mint(address(this), claimable());
        dbr.transfer(msg.sender, dbr.balanceOf(address(this)));
        lastClaim = block.timestamp;
    }

    function onDeposit() external {
        uint assetBal = asset.balanceOf(address(this));
        if(assetBal < balance()) asset.mint(address(this), balance() - assetBal);
        lastPay = block.timestamp;
    }
}
