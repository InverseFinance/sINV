// SPDX-License-Identifier: MIT License
pragma solidity 0.8.21;

import "lib/solmate/src/tokens/ERC4626.sol";

interface IInvEscrow {
    function onDeposit() external view returns (uint);
    function balance() external view returns (uint);
    function claimDBR() external;
    function claimable() external view returns (uint);
    function DBR() external view returns (address);
}

interface IMarket {
    function deposit(uint amount) external;
    function withdraw(uint amount) external;
    function createEscrow(address user) external returns (address);
    function dbr() external returns (address);
}

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

/**
 * @title sInv
 * @dev Auto-compounding ERC4626 wrapper for asset FiRM deposits utilizing xy=k auctions.
 * WARNING: While this vault is safe to be used as collateral in lending markets, it should not be allowed as a borrowable asset.
 * Any protocol in which sudden, large and atomic increases in the value of an asset may be a security risk should not integrate this vault.
 */
contract sInv is ERC4626 {
    
    uint constant MIN_BALANCE = 10**16; // 1 cent
    uint public constant MIN_SHARES = 10**18;
    uint public constant MAX_ASSETS = 10**32; // 100 trillion asset
    uint public period = 7 days;
    IMarket public immutable invMarket;
    IInvEscrow public immutable invEscrow;
    ERC20 public immutable DBR;
    address public gov;
    address public pendingGov;
    uint public minBuffer;
    uint public prevK;
    uint public targetK;
    uint public lastKUpdate;
    uint public periodRevenue;
    uint public lastPeriodRevenue;
    uint public lastBuy;

    /**
     * @dev Constructor for sInv contract.
     * WARNING: MIN_SHARES will always be unwithdrawable from the vault. Deployer should deposit enough to mint MIN_SHARES to avoid causing user grief.
     * @param _inv Address of the asset token.
     * @param _invMarket Address of the asset FiRM market.
     * @param _gov Address of the governance.
     * @param _K Initial value for the K variable used in calculations.
     */
    constructor(
        address _inv,
        address _invMarket,
        address _gov,
        uint _K
    ) ERC4626(ERC20(_inv), "Staked Inv", "sasset") {
        require(_K > 0, "_K must be positive");
        invMarket = IMarket(_invMarket);
        invEscrow = IInvEscrow(invMarket.createEscrow(address(this)));
        DBR = ERC20(IMarket(_invMarket).dbr());
        gov = _gov;
        targetK = _K;
        asset.approve(address(invMarket), type(uint).max);
    }

    modifier onlyGov() {
        require(msg.sender == gov, "ONLY GOV");
        _;
    }

    /**
     * @dev Hook that is called after tokens are deposited into the contract.
     * @param assets The amount of assets that were deposited.
     */    
    function afterDeposit(uint256 assets, uint256) internal override {
        require(totalSupply >= MIN_SHARES, "Shares below MIN_SHARES");
        uint invBal = asset.balanceOf(address(this));
        if(invBal < minBuffer){
            asset.transfer(address(invEscrow), invBal);
        } else {
            asset.transfer(address(invEscrow), invBal - minBuffer);
        }
        invEscrow.onDeposit();
    }

    /**
     * @dev Hook that is called before tokens are withdrawn from the contract.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to withdraw
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        uint _totalAssets = totalAssets();
        require(totalAssets() >= assets + MIN_BALANCE, "Insufficient assets");
        require(totalSupply - shares >= MIN_SHARES, "Shares below MIN_SHARES");
        uint invBal = asset.balanceOf(address(this));
        if(assets > invBal) {
            uint withdrawAmount = assets - invBal + minBuffer;
            if(_totalAssets < withdrawAmount){
                invMarket.withdraw(assets - invBal);
            } else {
                invMarket.withdraw(withdrawAmount);
            }
        }
    }

    /**
     * @dev Calculates the total assets controlled by the contract.
     * Period revenue is distributed linearly over the following week.
     * @return The total assets in the contract.
     */
    function totalAssets() public view override returns (uint) {
        uint timeElapsed = block.timestamp % period;
        //TODO: Inspect this more thoroughly
        uint remainingLastRevenue = lastPeriodRevenue * (period - timeElapsed) / period;
        uint lockedRevenue = remainingLastRevenue + periodRevenue;
        uint actualAssets;
        if(invEscrow.balance() > lockedRevenue){
            actualAssets = invEscrow.balance() - lockedRevenue;
        }
        return actualAssets < MAX_ASSETS ? actualAssets : MAX_ASSETS;
    }

    function updatePeriodRevenue(uint newRevenue) internal {
        if(block.timestamp / period > lastBuy / period) {
            lastPeriodRevenue = periodRevenue;
            periodRevenue = newRevenue;
            lastBuy = block.timestamp;
        } else {
            periodRevenue += newRevenue;
        }
    }

    /**
     * @dev Returns the current value of K, which is a weighted average between prevK and targetK.
     * @return The current value of K.
     */
    function getK() public view returns (uint) {
        uint timeElapsed = block.timestamp - lastKUpdate;
        if(timeElapsed > period) {
            return targetK;
        }
        uint targetWeight = timeElapsed;
        uint prevWeight = period - timeElapsed;
        return (prevK * prevWeight + targetK * targetWeight) / period;
    }

    /**
     * @dev Calculates the asset reserve based on the current DBR reserve.
     * @return The calculated asset reserve.
     */
    function getInvReserve() public view returns (uint) {
        return getK() / getDbrReserve();
    }

    /**
     * @dev Calculates the asset reserve for a given DBR reserve.
     * @param DBRReserve The DBR reserve value.
     * @return The calculated asset reserve.
     */
    function getInvReserve(uint DBRReserve) public view returns (uint) {
        return getK() / DBRReserve;
    }

    /**
     * @dev Returns the current DBR reserve as the sum of DBR balance and claimable DBR
     * @return The current DBR reserve.
     */
    function getDbrReserve() public view returns (uint) {
        return DBR.balanceOf(address(this)) + invEscrow.claimable();
    }

    /**
     * @dev Sets a new target K value.
     * @param _K The new target K value.
     */
    function setTargetK(uint _K) external onlyGov {
        require(_K > getDbrReserve(), "K must be larger than DBR reserve");
        prevK = getK();
        targetK = _K;
        lastKUpdate = block.timestamp;
        emit SetTargetK(_K);
    }
    
    /**
     * @dev Sets the new revenue accrual and K updating period.
     * @param _period The new revenue and K updating period.
     */
    function setPeriod(uint _period) external onlyGov {
        period = _period;
        emit SetPeriod(_period);
    }

    /**
     * @dev Allows users to buy DBR with asset.
     * WARNING: Never expose this directly to a UI as it's likely to cause a loss unless a transaction is executed immediately.
     * Instead use the sInvHelper function or custom smart contract code.
     * @param exactInvIn The exact amount of asset to spend.
     * @param exactDbrOut The exact amount of DBR to receive.
     * @param to The address that will receive the DBR.
     */
    function buyDBR(uint exactInvIn, uint exactDbrOut, address to) external {
        //TODO: Implement reentracy guard if keeping flashBuyDBR function
        require(to != address(0), "Zero address");
        uint DBRBalance = getDbrReserve();
        if(exactDbrOut > DBR.balanceOf(address(this))){
            invEscrow.claimDBR();
        }
        uint k = getK();
        uint DBRReserve = DBRBalance - exactDbrOut;
        uint invReserve = k / DBRBalance + exactInvIn;
        require(invReserve * DBRReserve >= k, "Invariant");
        updatePeriodRevenue(exactInvIn);
        DBR.transfer(to, exactDbrOut);
        emit Buy(msg.sender, to, exactInvIn, exactDbrOut);
    }

    /**
     * @dev Allows users to buy DBR with asset.
     * WARNING: Never expose this directly to a UI as it's likely to cause a loss unless a transaction is executed immediately.
     * Instead use the sInvHelper function or custom smart contract code.
     * @param exactInvIn The exact amount of asset to spend.
     * @param exactDbrOut The exact amount of DBR to receive.
     * @param to The address that will receive the DBR.
     */
    function flashBuyDBR(uint exactInvIn, uint exactDbrOut, address to) external {
        //TODO: Implement reentracy guards for buy functions
        uint DBRBalance = getDbrReserve();
        if(exactDbrOut > DBR.balanceOf(address(this))){
            invEscrow.claimDBR();
        }
        uint k = getK();
        uint DBRReserve = DBRBalance - exactDbrOut;
        uint invReserve = k / DBRBalance + exactInvIn;
        uint invBal = asset.balanceOf(address(this));
        uint sharesBefore = totalSupply;
        require(invReserve * DBRReserve >= k, "Invariant");
        DBR.transfer(to, exactDbrOut);
        to.call("");
        //TODO: Make sure there's no way to increase invBalance, in which the flash buyer can immediately withdraw
        require(invBal + exactInvIn <= asset.balanceOf(address(this)), "Failed flash buy");
        require(sharesBefore == totalSupply, "Failed flash buy");
        updatePeriodRevenue(exactInvIn);
        emit Buy(msg.sender, to, exactInvIn, exactDbrOut);
    }

    /**
     * @dev Sets a new pending governance address.
     * @param _gov The address of the new pending governance.
     */
    function setPendingGov(address _gov) external onlyGov {
        pendingGov = _gov;
    }

    /**
     * @dev Allows the pending governance to accept its role.
     */
    function acceptGov() external {
        require(msg.sender == pendingGov, "ONLY PENDINGGOV");
        gov = pendingGov;
        pendingGov = address(0);
    }

    /**
     * @dev Re-approves the asset token to be spent by the InvMarket contract.
     */
    function reapprove() external {
        asset.approve(address(invMarket), type(uint).max);
    }

    /**
     * @dev Allows governance to sweep any ERC20 token from the contract.
     * @dev Excludes the ability to sweep DBR tokens.
     * @param token The address of the ERC20 token to sweep.
     * @param amount The amount of tokens to sweep.
     * @param to The recipient address of the swept tokens.
     */
    function sweep(address token, uint amount, address to) public onlyGov {
        require(address(DBR) != token, "Not authorized");
        require(address(asset) != token, "Not authorized");
        IERC20(token).transfer(to, amount);
    }

    event Buy(address indexed caller, address indexed to, uint exactInvIn, uint exactDbrOut);
    event SetTargetK(uint newTargetK);
    event SetPeriod(uint newPeriod);
}
