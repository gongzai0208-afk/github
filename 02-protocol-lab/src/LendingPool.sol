// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {InterestModel} from "./InterestModel.sol";
import {MathX} from "./libraries/MathX.sol";

/// @notice Single-collateral lending market whose liquidity is an ERC-4626 share.
///
///         Lenders `deposit` the loan asset and receive shares. Borrowers post one collateral token
///         and borrow the loan asset. Interest accrues into `totalDebt`, which is part of
///         `totalAssets`, so it belongs to share holders pro rata. A liquidation that cannot recover
///         the debt seizes all collateral and writes the remainder off, which lowers `totalAssets`
///         and therefore the share price — the loss is socialised, not hidden.
contract LendingPool {
    using MathX for uint256;

    uint256 public constant WAD = 1e18;
    /// @dev Virtual offset mitigates the first-depositor share inflation attack.
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable asset;
    IERC20 public immutable collateral;
    IOracle public oracle;
    InterestModel public model;

    address public owner;
    address public pendingOwner;

    string public constant name = "Lending Pool Share";
    string public constant symbol = "lpSHARE";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalDebtShares;
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrual;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtSharesOf;

    uint256 public ltv = 0.75e18;
    uint256 public liquidationThreshold = 0.8e18;
    uint256 public liquidationBonus = 0.05e18;

    uint256 private _locked = 1;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seized);
    event BadDebt(address indexed user, uint256 amount);
    event RiskParamsChanged(uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus);
    event OracleChanged(address indexed oracle);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANT");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IERC20 asset_, IERC20 collateral_, IOracle oracle_, InterestModel model_, address owner_) {
        require(address(asset_) != address(0), "ASSET");
        require(address(collateral_) != address(0), "COLLATERAL");
        require(address(oracle_) != address(0), "ORACLE");
        require(address(model_) != address(0), "MODEL");
        require(owner_ != address(0), "OWNER");
        asset = asset_;
        collateral = collateral_;
        oracle = oracle_;
        model = model_;
        owner = owner_;
        lastAccrual = block.timestamp;
    }

    // ------------------------------------------------------------- accounting

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + totalDebt();
    }

    /// @notice Debt is tracked in shares, like the asset side. Without this, `totalDebt` and the sum
    ///         of per-user debt drift apart by rounding dust on every borrow and repay.
    function totalDebt() public view returns (uint256) {
        return totalDebtShares.mulDivDown(borrowIndex, WAD);
    }

    function debtOf(address user) public view returns (uint256) {
        return debtSharesOf[user].mulDivDown(borrowIndex, WAD);
    }

    function collateralValue(address user) public view returns (uint256) {
        return collateralOf[user].mulDivDown(oracle.price(), WAD);
    }

    function maxBorrow(address user) public view returns (uint256) {
        return collateralOf[user].mulDivDown(oracle.price(), WAD).mulDivDown(ltv, WAD);
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 debt = debtOf(user);
        if (debt == 0) return false;
        return collateralOf[user].mulDivDown(oracle.price(), WAD).mulDivDown(liquidationThreshold, WAD) < debt;
    }

    function accrue() public {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;
        if (totalDebtShares == 0) return;
        uint256 debt = totalDebt();
        uint256 total = asset.balanceOf(address(this)) + debt;
        uint256 utilization = (debt * WAD) / total;
        uint256 rps = model.ratePerSecond(utilization);
        borrowIndex += (borrowIndex * rps * dt) / WAD;
    }

    // ------------------------------------------------------------- 4626 views

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDivDown(totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDivDown(totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.mulDivUp(totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.mulDivUp(totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxWithdraw(address user) public view returns (uint256) {
        return convertToAssets(balanceOf[user]).min(asset.balanceOf(address(this)));
    }

    // ------------------------------------------------------------- 4626 actions

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        accrue();
        require(assets > 0, "AMOUNT");
        shares = previewDeposit(assets);
        require(shares > 0, "ZERO_SHARES");
        require(asset.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        accrue();
        require(shares > 0, "AMOUNT");
        assets = previewMint(shares);
        require(asset.transferFrom(msg.sender, address(this), assets), "TRANSFER");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external nonReentrant returns (uint256 shares) {
        accrue();
        require(assets > 0, "AMOUNT");
        shares = previewWithdraw(assets);
        require(shares <= balanceOf[owner_], "BALANCE");
        require(asset.balanceOf(address(this)) >= assets, "ILLIQUID");
        _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        require(asset.transfer(receiver, assets), "TRANSFER");
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        accrue();
        require(shares > 0, "AMOUNT");
        require(shares <= balanceOf[owner_], "BALANCE");
        assets = previewRedeem(shares);
        require(asset.balanceOf(address(this)) >= assets, "ILLIQUID");
        _spendAllowance(owner_, msg.sender, shares);
        _burn(owner_, shares);
        require(asset.transfer(receiver, assets), "TRANSFER");
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ------------------------------------------------------------- borrowing

    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT");
        require(collateral.transferFrom(msg.sender, address(this), amount), "TRANSFER");
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        accrue();
        require(amount > 0, "AMOUNT");
        require(amount <= collateralOf[msg.sender], "COLLATERAL");
        collateralOf[msg.sender] -= amount;
        require(debtOf(msg.sender) <= maxBorrow(msg.sender), "LTV");
        require(collateral.transfer(msg.sender, amount), "TRANSFER");
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount, address receiver) external nonReentrant {
        accrue();
        require(amount > 0, "AMOUNT");
        require(asset.balanceOf(address(this)) >= amount, "LIQUIDITY");
        uint256 shares = amount.mulDivUp(WAD, borrowIndex);
        uint256 newShares = debtSharesOf[msg.sender] + shares;
        require(newShares.mulDivDown(borrowIndex, WAD) <= maxBorrow(msg.sender), "LTV");
        debtSharesOf[msg.sender] = newShares;
        totalDebtShares += shares;
        require(asset.transfer(receiver, amount), "TRANSFER");
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant returns (uint256 paid) {
        accrue();
        uint256 shares = debtSharesOf[msg.sender];
        uint256 debt = shares.mulDivDown(borrowIndex, WAD);
        paid = amount.min(debt);
        require(paid > 0, "AMOUNT");
        uint256 burned = paid == debt ? shares : paid.mulDivUp(WAD, borrowIndex);
        if (burned > shares) burned = shares;
        debtSharesOf[msg.sender] = shares - burned;
        totalDebtShares -= burned;
        require(asset.transferFrom(msg.sender, address(this), paid), "TRANSFER");
        emit Repaid(msg.sender, paid);
    }

    /// @notice Repay an unhealthy position and receive collateral plus the bonus.
    ///         If the collateral cannot cover the debt, the remainder is written off.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        accrue();
        uint256 shares = debtSharesOf[user];
        require(shares > 0, "NO_DEBT");
        uint256 debt = shares.mulDivDown(borrowIndex, WAD);
        uint256 price = oracle.price();
        uint256 coll = collateralOf[user];
        require(coll.mulDivDown(price, WAD).mulDivDown(liquidationThreshold, WAD) < debt, "HEALTHY");

        uint256 maxRepay = coll.mulDivDown(price, WAD + liquidationBonus);
        uint256 repaid = repayAmount.min(debt).min(maxRepay);
        require(repaid > 0, "REPAY");

        uint256 seize = repaid.mulDivUp(WAD + liquidationBonus, price).min(coll);
        uint256 burned = repaid == debt ? shares : repaid.mulDivUp(WAD, borrowIndex);
        if (burned > shares) burned = shares;

        asset.transferFrom(msg.sender, address(this), repaid);
        collateralOf[user] = coll - seize;
        debtSharesOf[user] = shares - burned;
        totalDebtShares -= burned;

        require(collateral.transfer(msg.sender, seize), "TRANSFER");
        emit Liquidated(user, msg.sender, repaid, seize);

        if (debtSharesOf[user] > 0 && collateralOf[user] == 0) {
            uint256 badShares = debtSharesOf[user];
            debtSharesOf[user] = 0;
            totalDebtShares -= badShares;
            emit BadDebt(user, badShares.mulDivDown(borrowIndex, WAD));
        }
    }

    // ------------------------------------------------------------- ERC20 shares

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ZERO_ADDRESS");
        uint256 balance = balanceOf[from];
        require(balance >= amount, "BALANCE");
        unchecked {
            balanceOf[from] = balance - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ZERO_ADDRESS");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 balance = balanceOf[from];
        require(balance >= amount, "BALANCE");
        unchecked {
            balanceOf[from] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal {
        if (owner_ == spender) return;
        uint256 allowed = allowance[owner_][spender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) {
            unchecked {
                allowance[owner_][spender] = allowed - amount;
            }
        }
    }

    // ------------------------------------------------------------- admin

    function setOracle(IOracle newOracle) external onlyOwner {
        require(address(newOracle) != address(0), "ORACLE");
        oracle = newOracle;
        emit OracleChanged(address(newOracle));
    }

    function setRiskParams(uint256 ltv_, uint256 liquidationThreshold_, uint256 liquidationBonus_) external onlyOwner {
        require(ltv_ > 0 && ltv_ < liquidationThreshold_ && liquidationThreshold_ <= WAD, "THRESHOLD");
        require(liquidationBonus_ <= 0.5e18, "BONUS");
        ltv = ltv_;
        liquidationThreshold = liquidationThreshold_;
        liquidationBonus = liquidationBonus_;
        emit RiskParamsChanged(ltv_, liquidationThreshold_, liquidationBonus_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING");
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }
}
