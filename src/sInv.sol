// SPDX-License-Identifier: MIT License
pragma solidity ^0.8.21;

import "lib/solmate/src/tokens/ERC4626.sol";

interface IInvEscrow {
    function balance() external view returns (uint);
    function claimDBR() external;
    function claimable() external view returns (uint);
}

interface IMarket {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function dbr() external returns (address);
    function escrows(address user) external returns (address);
}

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

/**
 * @title sINV
 * @dev Auto-compounding ERC4626 wrapper for asset FiRM deposits utilizing xy=k auctions.
 * WARNING: While this vault is safe to be used as collateral in lending markets, it should not be allowed as a borrowable asset.
 * Any protocol in which sudden, large and atomic increases in the value of an asset may be a security risk should not integrate this vault.
 */
contract sINV is ERC4626{

    struct RevenueData {
        uint96 periodRevenue;
        uint96 lastPeriodRevenue;
        uint64 lastBuyPeriod;
    }

    struct KData {
        uint192 targetK;
        uint64 lastKUpdate;
    }
    
    uint256 public constant MIN_ASSETS = 10**16; // 1 cent
    uint256 public constant MIN_SHARES = 10**18;
    uint256 public constant MAX_ASSETS = 10**32; // 100 trillion asset
    uint256 public constant period = 7 days;
    uint256 public depositLimit;
    IMarket public immutable invMarket;
    IInvEscrow public immutable invEscrow;
    ERC20 public immutable DBR;
    RevenueData public revenueData;
    KData public kData;
    address public gov;
    address public guardian;
    address public pendingGov;
    uint256 public minBuffer;
    uint256 public prevK;

    function periodRevenue() external view returns(uint256){return revenueData.periodRevenue;}
    function lastPeriodRevenue() external view returns(uint256){return revenueData.lastPeriodRevenue;}
    function lastBuyPeriod() external view returns(uint256){return revenueData.lastBuyPeriod;}
    function targetK() external view returns(uint256){return kData.targetK;}
    function lastKUpdate() external view returns(uint256){return kData.lastKUpdate;}

    error OnlyGov();
    error OnlyPendingGov();
    error OnlyGuardian();
    error KTooLow(uint k, uint limit);
    error BelowMinShares();
    error AboveDepositLimit();
    error DepositLimitMustIncrease();
    error InsufficientAssets();
    error Invariant();
    error UnauthorizedTokenWithdrawal();

    /**
     * @dev Constructor for sINV contract.
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
        address _guardian,
        uint256 _depositLimit,
        uint256 _K
    ) ERC4626(ERC20(_inv), "Staked Inv", "sINV") {
        if(_K == 0) revert KTooLow(_K, 1);
        IMarket(_invMarket).deposit(0); //creates an escrow on behalf of the sINV contract
        invEscrow = IInvEscrow(IMarket(_invMarket).escrows(address(this)));
        invMarket = IMarket(_invMarket);
        DBR = ERC20(IMarket(_invMarket).dbr());
        gov = _gov;
        guardian = _guardian;
        kData.targetK = uint192(_K);
        depositLimit = _depositLimit;
        prevK = _K;
        asset.approve(address(invMarket), type(uint).max);
    }

    modifier onlyGov() {
        if(msg.sender != gov) revert OnlyGov();
        _;
    }

    modifier onlyPendingGov() {
        if(msg.sender != pendingGov) revert OnlyPendingGov();
        _;
    }

    modifier onlyGuardian() {
        if(msg.sender != guardian) revert OnlyGuardian();
        _;
    }

    /**
     * @dev Hook that is called after tokens are deposited into the contract.
     */    
    function afterDeposit(uint256, uint256) internal override {
        if(totalSupply < MIN_SHARES) revert BelowMinShares();
        if(totalAssets() > depositLimit) revert AboveDepositLimit();
        uint256 invBal = asset.balanceOf(address(this));
        if(invBal > minBuffer){
            invMarket.deposit(invBal - minBuffer);
        }
    }

    /**
     * @dev Hook that is called before tokens are withdrawn from the contract.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to withdraw
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        uint256 _totalAssets = totalAssets();
        if(_totalAssets < assets + MIN_ASSETS) revert InsufficientAssets();
        if(totalSupply < shares + MIN_SHARES) revert BelowMinShares();
        uint256 invBal = asset.balanceOf(address(this));
        if(assets > invBal) {
            uint256 withdrawAmount = assets - invBal + minBuffer;
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
        uint256 periodsSinceLastBuy = block.timestamp / period - revenueData.lastBuyPeriod;
        uint256 _lastPeriodRevenue = revenueData.lastPeriodRevenue;
        uint256 _periodRevenue = revenueData.periodRevenue;
        uint256 invBal = invEscrow.balance() + asset.balanceOf(address(this));
        if(periodsSinceLastBuy > 1){
            return invBal < MAX_ASSETS ? invBal : MAX_ASSETS;
        } else if(periodsSinceLastBuy == 1) {
            _lastPeriodRevenue = _periodRevenue;
            _periodRevenue = 0;
        }
        uint256 remainingLastRevenue = _lastPeriodRevenue * (period - block.timestamp % period) / period;
        uint256 lockedRevenue = remainingLastRevenue + _periodRevenue;
        uint256 actualAssets;
        if(invBal > lockedRevenue){
            actualAssets = invBal - lockedRevenue;
        }
        return actualAssets < MAX_ASSETS ? actualAssets : MAX_ASSETS;
    }

    function updatePeriodRevenue(uint96 newRevenue) internal {
        uint256 currentPeriod = block.timestamp / period;
        uint256 periodsSinceLastBuy = currentPeriod - revenueData.lastBuyPeriod;
        if(periodsSinceLastBuy > 1){
            revenueData.lastPeriodRevenue = 0;
            revenueData.periodRevenue = newRevenue;
            revenueData.lastBuyPeriod = uint64(currentPeriod);
        } else if(periodsSinceLastBuy == 1) {
            revenueData.lastPeriodRevenue = revenueData.periodRevenue;
            revenueData.periodRevenue = newRevenue;
            revenueData.lastBuyPeriod = uint64(currentPeriod);
        } else {
            revenueData.periodRevenue += newRevenue;
        }
    }

    /**
     * @dev Returns the current value of K, which is a weighted average between prevK and kData.targetK.
     * @return The current value of K.
     */
    function getK() public view returns (uint) {
        uint256 timeElapsed = block.timestamp - kData.lastKUpdate;
        if(timeElapsed > period) {
            return kData.targetK;
        }
        uint256 prevWeight = period - timeElapsed;
        return (prevK * prevWeight + kData.targetK * timeElapsed) / period;
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
    function getInvReserve(uint256 DBRReserve) public view returns (uint) {
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
    function setTargetK(uint256 _K) external onlyGov {
        if(_K < getDbrReserve()) revert KTooLow(_K, getDbrReserve());
        prevK = getK();
        kData.targetK = uint192(_K);
        kData.lastKUpdate = uint64(block.timestamp);
        emit SetTargetK(_K);
    }

    /**
     * @notice Set the min buffer
     * @dev Min buffer is the buffer of INV held by the sINV contract, which can be withdrawn much more cheaply than if they were staked
     * @param _minBuffer The new min buffer
     */
    function setMinBuffer(uint256 _minBuffer) external onlyGov {
        minBuffer = _minBuffer;
        emit SetMinBuffer(_minBuffer);
    }

    /**
     * @dev Allows users to buy DBR with asset.
     * WARNING: Never expose this directly to a UI as it's likely to cause a loss unless a transaction is executed immediately.
     * Instead use the sINVHelper function or custom smart contract code.
     * @param exactInvIn The exact amount of asset to spend.
     * @param exactDbrOut The exact amount of DBR to receive.
     * @param to The address that will receive the DBR.
     */
    function buyDBR(uint256 exactInvIn, uint256 exactDbrOut, address to) external {
        require(exactInvIn <= type(uint96).max, "EXCEED UINT96");
        uint256 DBRBalance = DBR.balanceOf(address(this));
        if(exactDbrOut > DBRBalance){
            invEscrow.claimDBR();
            DBRBalance = DBR.balanceOf(address(this));
        } else {
            DBRBalance += invEscrow.claimable(); 
        }
        uint256 k = getK();
        uint256 DBRReserve = DBRBalance - exactDbrOut;
        uint256 invReserve = k / DBRBalance + exactInvIn;
        if(invReserve * DBRReserve < k) revert Invariant();
        updatePeriodRevenue(uint96(exactInvIn));
        asset.transferFrom(msg.sender, address(this), exactInvIn);
        DBR.transfer(to, exactDbrOut);
        emit Buy(msg.sender, to, exactInvIn, exactDbrOut);
    }

    /**
     * @notice Sets a new depositLimit. Only callable by guardian.
     * @dev Deposit limit must always increase
     * @param _depositLimit The new deposit limit
     */
    function setDepositLimit(uint _depositLimit) external onlyGuardian {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the guardian that can increase the deposit limit. Only callable by governance.
     * @param _guardian The new guardian.
     */
    function setGuardian(address _guardian) external onlyGov {
        guardian = _guardian;
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
    function acceptGov() external onlyPendingGov {
        gov = pendingGov;
        pendingGov = address(0);
    }

    /**
     * @dev Allows governance to sweep any ERC20 token from the contract.
     * @dev Excludes the ability to sweep DBR tokens.
     * @param token The address of the ERC20 token to sweep.
     * @param amount The amount of tokens to sweep.
     * @param to The recipient address of the swept tokens.
     */
    function sweep(address token, uint256 amount, address to) public onlyGov {
        if(address(DBR) == token ||
            address(asset) == token)
            revert UnauthorizedTokenWithdrawal();
        IERC20(token).transfer(to, amount);
    }
    
    /**
     * @notice Allows anyone to reapprove inv spending for invMarket
     */
    function reapprove() external {
        asset.approve(address(invMarket), type(uint).max);
    }
    

    event Buy(address indexed caller, address indexed to, uint256 exactInvIn, uint256 exactDbrOut);
    event SetTargetK(uint256 newTargetK);
    event SetMinBuffer(uint256 newMinBuffer);
}
