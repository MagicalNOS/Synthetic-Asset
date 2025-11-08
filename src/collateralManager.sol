                                                                                      
                                                                                                              
//     ▄▄▄▄                                           ▄▄▄▄▄▄                        ▄▄                           
//   ██▀▀▀▀█                                          ██▀▀▀▀██                      ██                    ██     
//  ██▀        ▄████▄   ▄▄█████▄  ████▄██▄   ▄████▄   ██    ██   ▄█████▄  ▄▄█████▄  ██ ▄██▀    ▄████▄   ███████  
//  ██        ██▀  ▀██  ██▄▄▄▄ ▀  ██ ██ ██  ██▀  ▀██  ███████    ▀ ▄▄▄██  ██▄▄▄▄ ▀  ██▄██     ██▄▄▄▄██    ██     
//  ██▄       ██    ██   ▀▀▀▀██▄  ██ ██ ██  ██    ██  ██    ██  ▄██▀▀▀██   ▀▀▀▀██▄  ██▀██▄    ██▀▀▀▀▀▀    ██     
//   ██▄▄▄▄█  ▀██▄▄██▀  █▄▄▄▄▄██  ██ ██ ██  ▀██▄▄██▀  ██▄▄▄▄██  ██▄▄▄███  █▄▄▄▄▄██  ██  ▀█▄   ▀██▄▄▄▄█    ██▄▄▄  
//     ▀▀▀▀     ▀▀▀▀     ▀▀▀▀▀▀   ▀▀ ▀▀ ▀▀    ▀▀▀▀    ▀▀▀▀▀▀▀    ▀▀▀▀ ▀▀   ▀▀▀▀▀▀   ▀▀   ▀▀▀    ▀▀▀▀▀      ▀▀▀▀  
                                                                                                              
// Author: Kevin Lee
// Date: 2025-11-6
// Description: Collateral Manager Contract

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";

contract CollateralManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========== Events ============
    event CollateralDeposited(address indexed staker, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed staker, address indexed asset, uint256 amount);
    event SyntheticAssetMinted(address indexed staker, address indexed synAsset, uint256 amount);
    event SyntheticAssetBurned(address indexed staker, address indexed synAsset, uint256 amount);
    event LiquidationExecuted(address indexed liquidator, address indexed user, uint256 debtRepaid);

    // ============ Errors ============
    error CollateralManager__MismatchedArrays();
    error CollateralManager__TrasferFailed();
    error CollateralManager__UnsupportedAsset();
    error CollateralManager__UnsupportedSyntheticAsset();
    error CollateralManager__InsufficientCollateral();
    error CollateralManager__HealthyPosition();
    error CollateralManager__InvalidLiquidation();
    error CollateralManager__RiskyPosition();

    // ============ State Variables ============
    uint256 public constant DECIMAL_PRECISION = 1e18; // 18 decimals precision
    uint256 public constant HEALTH_FACTOR = 3e18; // 300%
    uint256 public constant MINT_RISK_RATIO = 2e18; // 200%
    uint256 public constant LIQUIDATION_RISK_RATIO = 1_8e18; // 180%
    uint256 public constant LIQUIDATION_THRESHOLD = 1_5e18; // 150%
    uint256 public constant LIQUIDATION_BONUS = 5e16; // 5%

    IPriceOracle public immutable s_priceOracle;
    IDebtPool public immutable s_debtPool;
    address private immutable i_sUSD;

    // staker -> asset address -> amount(collateral BTC not sBTC)
    mapping(address => mapping(address => uint256)) private s_stakerCollaterals;

    // list of supported assets
    address[] private s_supportedAssetsList;

    // asset address => is supported
    mapping(address => bool) private s_supportedAssets;

    // synthetic asset address => is supported
    mapping(address => bool) private s_supportedSyntheticAssets;

    // asset address => collateral ratio 

    constructor(
        address priceOracleAddress,
        address debtPoolAddress,
        address[] memory supportedAssets,
        address[] memory supportedSyntheticAssets
    ) {
        s_priceOracle = IPriceOracle(priceOracleAddress);
        s_debtPool = IDebtPool(debtPoolAddress);

        for(uint256 i = 0; i < supportedAssets.length; i++){
            s_supportedAssets[supportedAssets[i]] = true;
            s_supportedAssetsList.push(supportedAssets[i]);
        }

        for(uint256 i = 0; i < supportedSyntheticAssets.length; i++){
            s_supportedSyntheticAssets[supportedSyntheticAssets[i]] = true;
        }
    }

    // @param asset: collateral asset address
    // @param amount: amount of collateral to deposit
    // @Kevin this function transfers the collateral asset from user to this contract
    function depositCollateral(address asset, uint256 amount) external nonReentrant {
        if(!s_supportedAssets[asset]){
            revert CollateralManager__UnsupportedAsset();
        }

        uint256 preBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        s_stakerCollaterals[msg.sender][asset] += amount;
        uint256 postBalance = IERC20(asset).balanceOf(address(this));
        if(postBalance - preBalance != amount){
            revert CollateralManager__TrasferFailed();
        }

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    // @param asset: collateral asset address
    // @param amount: amount of collateral to withdraw
    // @Kevin user can only withdraw if their health factor after withdrawal is above LIQUIDATION_RISK_RATIO
    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        if(s_stakerCollaterals[msg.sender][asset] < amount){
            revert CollateralManager__InsufficientCollateral();
        }
        s_stakerCollaterals[msg.sender][asset] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);

        // Check health factor after withdrawal
        uint256 userDebt = s_debtPool.getUserDebt(msg.sender);
        if(userDebt > 0){
            uint256 userCollateral = getUserCollateralUSD(msg.sender);
            if(userCollateral * DECIMAL_PRECISION / userDebt < LIQUIDATION_RISK_RATIO){
                revert CollateralManager__RiskyPosition();
            }
        }

        // remove asset entry if both collateral and debt are zero(user may didn't use this system)
        // can get gas refund this way
        if(userDebt == 0 && s_stakerCollaterals[msg.sender][asset] == 0){
            delete s_stakerCollaterals[msg.sender][asset];
        }

        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to mint
    // @Kevin user can only mint up to theirself collateral value / MINT_RISK_RATIO
    // @Kevin Follow FREE-PI Standard
    function mintSyntheticAsset(address synAsset, uint256 amount) external nonReentrant{
        if(!s_supportedSyntheticAssets[synAsset]){
            revert CollateralManager__UnsupportedSyntheticAsset();
        }

        // calculate total collateral value in USD
        uint256 userDebt = s_debtPool.getUserDebt(msg.sender);
        uint256 userCollateral = getUserCollateralUSD(msg.sender);
        uint256 increasedDebt = uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset())) * amount / 1e18;
        uint256 newDebt = userDebt + increasedDebt;
        // check if health factor is above MINT_RISK_RATIO after minting
        if(userCollateral * DECIMAL_PRECISION / newDebt < MINT_RISK_RATIO){
            revert CollateralManager__InsufficientCollateral();
        }

        s_debtPool.increaseDebt(msg.sender, increasedDebt);
        ISynAsset(synAsset).mint(msg.sender, amount);

        // check if health factor is still above LIQUIDATION_RISK_RATIO after minting
        uint256 finalUserDebt = s_debtPool.getUserDebt(msg.sender);
        if(userCollateral * DECIMAL_PRECISION / finalUserDebt < LIQUIDATION_RISK_RATIO){
            revert CollateralManager__InsufficientCollateral();
        }

        emit SyntheticAssetMinted(msg.sender, synAsset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to burn
    // @Kevin user can only burn up to theirself debt amount
    function burnSyntheticAsset(address synAsset, uint256 amount) external nonReentrant{
        if(!s_supportedSyntheticAssets[synAsset]){
            revert CollateralManager__UnsupportedSyntheticAsset();
        }

        uint256 decreasedDebt = uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset())) * amount / 1e18;
        // If user tries to burn more than their debt, adjust the amount to burn only their debt
        if(decreasedDebt > s_debtPool.getUserDebt(msg.sender)){
            decreasedDebt = s_debtPool.getUserDebt(msg.sender);
            amount = (decreasedDebt * 1e18) / uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset()));
        }
        s_debtPool.decreaseDebt(msg.sender, decreasedDebt);
        ISynAsset(synAsset).burn(msg.sender, amount);
        emit SyntheticAssetBurned(msg.sender, synAsset, amount);
    }

    // @param user: the user to be liquidated
    // @param amount: amount of debt to liquidate in USD
    // @Kevin liquidator will receive collateral + bonus. sUSD will be used to settle the debt
    // @Kevin I want liquidator to share some profit to the staker by swaping other synthetic assets to sUSD later.
    function liquidate(address user, uint256 amount) external nonReentrant{
        // first check if user is eligible for liquidation
        uint256 userDebt = s_debtPool.getUserDebt(user);
        uint256 userCollateral = getUserCollateralUSD(user);
        if(userDebt == 0 || userCollateral * DECIMAL_PRECISION / userDebt >= LIQUIDATION_THRESHOLD){
            revert CollateralManager__HealthyPosition();
        }
        // Approximate debt to liquidate
        uint256 maxDebtToLiquidate = userDebt - (userCollateral * DECIMAL_PRECISION / LIQUIDATION_RISK_RATIO);
        uint256 debtToLiquidate = amount > maxDebtToLiquidate ? maxDebtToLiquidate : amount;
        // Liquidation based on the proportion of each collateral asset
        for(uint i = 0; i < s_supportedAssetsList.length; ++i){
            address asset = s_supportedAssetsList[i];
            uint256 assetCollateral = s_stakerCollaterals[user][asset];
            uint256 allCollateralUSD = getUserCollateralUSD(user);
            if(assetCollateral == 0){
                continue;
            }
            uint256 assetValueUSD = (assetCollateral * uint256(s_priceOracle.getPrice(asset))) / 1e18;
            uint256 liquidateAmountUSD = ((assetValueUSD * DECIMAL_PRECISION / allCollateralUSD) * debtToLiquidate) / DECIMAL_PRECISION;
            uint256 bonusAmountUSD = (liquidateAmountUSD * LIQUIDATION_BONUS) / DECIMAL_PRECISION;
            uint256 totalPayoutAsset = (liquidateAmountUSD + bonusAmountUSD) * DECIMAL_PRECISION / uint256(s_priceOracle.getPrice(asset));

            // Transfer collateral asset to liquidator
            s_stakerCollaterals[user][asset] -= totalPayoutAsset;
            IERC20(asset).safeTransfer(msg.sender, totalPayoutAsset);

            // Burn sUSD from liquidator and decrease user debt
            ISynAsset(i_sUSD).burn(msg.sender, liquidateAmountUSD);
            s_debtPool.decreaseDebt(user, liquidateAmountUSD);
        }

        // Check the user's health factor after liquidation
        uint256 updatedUserDebt = s_debtPool.getUserDebt(user);
        uint256 updatedUserCollateral = getUserCollateralUSD(user);
        uint256 newHealthFactor = updatedUserCollateral * DECIMAL_PRECISION / updatedUserDebt;
        uint256 oldHealthFactor = userCollateral * DECIMAL_PRECISION / userDebt;
        if(newHealthFactor <= oldHealthFactor){
            revert CollateralManager__InvalidLiquidation();
        }
        emit LiquidationExecuted(msg.sender, user, debtToLiquidate);
    }

    // ============ Getter Functions ============
    
    function isAssetSupported(address asset) public view returns (bool){
        return s_supportedAssets[asset];
    }

    function isSyntheticAssetSupported(address synAsset) public view returns (bool){
        return s_supportedSyntheticAssets[synAsset];
    }

    function getSupportedAssets() public view returns (address[] memory){
        return s_supportedAssetsList;
    }

    function getStakerCollateral(address staker, address asset) public view returns (uint256){
        return s_stakerCollaterals[staker][asset];
    }

    function getUserCollateralUSD(address user) public view returns (uint256){
        uint256 totalCollateralUSD = 0;
        for(uint256 i = 0; i < s_supportedAssetsList.length; i++){
            address asset = s_supportedAssetsList[i];
            uint256 assetAmount = s_stakerCollaterals[user][asset];
            if(assetAmount > 0){
                int256 assetPrice = s_priceOracle.getPrice(asset);
                totalCollateralUSD += (assetAmount * uint256(assetPrice)) / 1e18;
            }
        }
        return totalCollateralUSD;
    }
}
