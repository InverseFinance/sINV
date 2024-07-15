// SPDX-License-Identifier: MIT License
pragma solidity 0.8.21;

import "lib/solmate/src/tokens/ERC4626.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IInvEscrow {
    function onDeposit() external;
    function balance() external view returns (uint);
    function claimDBR() external;
    function claimable() external view returns (uint);
    function DBR() external view returns (address);
    function distributor() external view returns (address);
}

interface IMarket {
    function deposit(uint256 amount) external;
    function deposit(uint256 amount, address user) external;
    function withdraw(uint256 amount) external;
    function dbr() external returns (address);
    function collateral() external returns (address);
    function predictEscrow(address user) external returns (address);
}

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

interface IDistributor {
    function claimable(address) external view returns(uint);
}

interface IFlashSwapIntegrator {
    function flashSwapCallback(bytes calldata data) external;
}

/**
 * @title sINV
 * @dev Auto-compounding ERC4626 wrapper for asset FiRM deposits utilizing xy=k auctions.
 * WARNING: While this vault is safe to be used as collateral in lending markets, it should not be allowed as a borrowable asset.
 * Any protocol in which sudden, large and atomic increases in the value of an asset may be a security risk should not integrate this vault.
 */
contract sINV is ERC4626 {
    
    uint256 public constant MIN_ASSETS = 10**16; // 1 cent
    uint256 public constant MIN_SHARES = 10**18;
    uint256 public constant MAX_ASSETS = 10**32; // 100 trillion asset
    uint256 public period = 7 days;
    IMarket public immutable invMarket;
    IInvEscrow public invEscrow;
    ERC20 public immutable DBR;
    ERC20 public immutable INV;
    address public gov;
    address public pendingGov;
    uint256 public minBuffer;
    uint256 public prevK;
    uint256 public targetK;
    uint256 public lastKUpdate;
    uint256 public periodRevenue;
    uint256 public lastPeriodRevenue;
    uint256 public lastBuy;

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
        uint256 _K
    ) ERC4626(ERC20(_inv), "Staked Inv", "sINV") {
        require(_K > 0, "_K must be positive");
        IMarket(_invMarket).deposit(0); //creates an escrow on behalf of the sINV contract
        invEscrow = IInvEscrow(IMarket(_invMarket).predictEscrow(address(this)));
        invMarket = IMarket(_invMarket);
        DBR = ERC20(IMarket(_invMarket).dbr());
        INV = ERC20(IMarket(_invMarket).collateral());
        gov = _gov;
        targetK = _K;
        prevK = _K;
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
        uint256 invBal = asset.balanceOf(address(this));
        if(invBal > minBuffer){
            asset.transfer(address(invEscrow), invBal - minBuffer);
            invEscrow.onDeposit();
        }
    }

    /**
     * @dev Hook that is called before tokens are withdrawn from the contract.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to withdraw
     */
    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        uint256 _totalAssets = totalAssets();
        require(totalAssets() >= assets + MIN_ASSETS, "Insufficient assets");
        require(totalSupply >= shares + MIN_SHARES, "Shares below MIN_SHARES");
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
        uint256 periodsSinceLastBuy = block.timestamp / period - lastBuy / period;
        uint256 _lastPeriodRevenue = lastPeriodRevenue;
        uint256 _periodRevenue = periodRevenue;
        uint256 invBal = invEscrow.balance() + asset.balanceOf(address(this));
        if(periodsSinceLastBuy > 1){
            return invBal < MAX_ASSETS ? invBal : MAX_ASSETS;
        } else if(periodsSinceLastBuy == 1) {
            _lastPeriodRevenue = periodRevenue;
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

    function updatePeriodRevenue(uint256 newRevenue) internal {
        if(block.timestamp / period > lastBuy / period) {
            lastPeriodRevenue = periodRevenue;
            periodRevenue = newRevenue;
        } else {
            periodRevenue += newRevenue;
        }
        lastBuy = block.timestamp;
    }

    /**
     * @dev Returns the current value of K, which is a weighted average between prevK and targetK.
     * @return The current value of K.
     */
    function getK() public view returns (uint) {
        uint256 timeElapsed = block.timestamp - lastKUpdate;
        if(timeElapsed > period) {
            return targetK;
        }
        uint256 targetWeight = timeElapsed;
        uint256 prevWeight = period - timeElapsed;
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
        require(_K > getDbrReserve(), "K must be larger than DBR reserve");
        prevK = getK();
        targetK = _K;
        lastKUpdate = block.timestamp;
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
     * @dev Sets the new revenue accrual and K updating period.
     * @param _period The new revenue and K updating period.
     */
    function setPeriod(uint256 _period) external onlyGov {
        period = _period;
        emit SetPeriod(_period);
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
        require(to != address(0), "Zero address");
        uint256 DBRBalance = getDbrReserve();
        if(exactDbrOut > DBR.balanceOf(address(this))){
            invEscrow.claimDBR();
        }
        uint256 k = getK();
        uint256 DBRReserve = DBRBalance - exactDbrOut;
        uint256 invReserve = k / DBRBalance + exactInvIn;
        require(invReserve * DBRReserve >= k, "Invariant");
        updatePeriodRevenue(exactInvIn);
        INV.transferFrom(msg.sender, address(this), exactInvIn);
        DBR.transfer(to, exactDbrOut);
        emit Buy(msg.sender, to, exactInvIn, exactDbrOut);
    }

    /**
     * @dev Allows users to buy DBR with asset.
     * WARNING: Never expose this directly to a UI as it's likely to cause a loss unless a transaction is executed immediately.
     * Instead use the sINVHelper function or custom smart contract code.
     * @param exactInvIn The exact amount of asset to spend.
     * @param exactDbrOut The exact amount of DBR to receive.
     * @param to The address that will receive the DBR.
     */
    function flashBuyDBR(uint256 exactInvIn, uint256 exactDbrOut, address to, bytes calldata data) external {
        uint256 DBRBalance = getDbrReserve();
        if(exactDbrOut > DBR.balanceOf(address(this))){
            invEscrow.claimDBR();
        }
        uint256 k = getK();
        uint256 DBRReserve = DBRBalance - exactDbrOut;
        uint256 invReserve = k / DBRBalance + exactInvIn;
        uint256 invBal = asset.balanceOf(address(this));
        uint256 sharesBefore = totalSupply;
        require(invReserve * DBRReserve >= k, "Invariant");
        updatePeriodRevenue(exactInvIn);
        DBR.transfer(to, exactDbrOut);
        IFlashSwapIntegrator(to).flashSwapCallback(data);
        //TODO: Make sure there's no way to increase invBalance, in which the flash buyer can immediately withdraw
        require(invBal + exactInvIn <= asset.balanceOf(address(this)), "Failed flash buy");
        require(sharesBefore == totalSupply, "Failed flash buy");
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
     * @dev Allows governance to sweep any ERC20 token from the contract.
     * @dev Excludes the ability to sweep DBR tokens.
     * @param token The address of the ERC20 token to sweep.
     * @param amount The amount of tokens to sweep.
     * @param to The recipient address of the swept tokens.
     */
    function sweep(address token, uint256 amount, address to) public onlyGov {
        require(address(DBR) != token, "Not authorized");
        require(address(asset) != token, "Not authorized");
        IERC20(token).transfer(to, amount);
    }

    event Buy(address indexed caller, address indexed to, uint256 exactInvIn, uint256 exactDbrOut);
    event SetTargetK(uint256 newTargetK);
    event SetPeriod(uint256 newPeriod);
    event SetMinBuffer(uint256 newMinBuffer);
}
