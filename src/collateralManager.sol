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
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

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
    error CollateralManager__ZeroAmount();
    error CollateralManager__ProtocolInvariantViolated();

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

    constructor(
        address priceOracleAddress,
        address debtPoolAddress,
        address sUSD,
        address[] memory supportedAssets,
        address[] memory supportedSyntheticAssets
    ) {
        s_priceOracle = IPriceOracle(priceOracleAddress);
        s_debtPool = IDebtPool(debtPoolAddress);
        i_sUSD = sUSD;

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
    // @Kevin Follow FREI-PI Standard
    function depositCollateral(address asset, uint256 amount) external nonReentrant {
        // F: Function Requirements
        if(!s_supportedAssets[asset]){
            revert CollateralManager__UnsupportedAsset();
        }
        if(amount == 0){
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects
        uint256 preBalance = IERC20(asset).balanceOf(address(this));
        s_stakerCollaterals[msg.sender][asset] += amount;

        // I: Interactions
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // PI: Protocol Invariants
        // PI-1: Balance change must match deposit amount
        uint256 postBalance = IERC20(asset).balanceOf(address(this));
        if(postBalance - preBalance != amount){
            revert CollateralManager__TrasferFailed();
        }

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    // @param asset: collateral asset address
    // @param amount: amount of collateral to withdraw
    // @Kevin user can only withdraw if their health factor after withdrawal is above LIQUIDATION_RISK_RATIO
    // @Kevin Follow FREI-PI Standard
    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        // F: Function Requirements
        if(!s_supportedAssets[asset]){
            revert CollateralManager__UnsupportedAsset();
        }
        if(s_stakerCollaterals[msg.sender][asset] < amount){
            revert CollateralManager__InsufficientCollateral();
        }
        if(amount == 0){
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects
        uint256 userDebtBefore = s_debtPool.getUserDebt(msg.sender);
        s_stakerCollaterals[msg.sender][asset] -= amount;

        // I: Interactions
        IERC20(asset).safeTransfer(msg.sender, amount);

        // PI: Protocol Invariants
        // PI-1: Health factor must remain above liquidation threshold if user has debt
        uint256 userDebt = s_debtPool.getUserDebt(msg.sender);
        if(userDebt > 0){
            uint256 userCollateral = getUserCollateralUSD(msg.sender);
            if(userCollateral * DECIMAL_PRECISION / userDebt < LIQUIDATION_RISK_RATIO){
                revert CollateralManager__RiskyPosition();
            }
        }
        // PI-2: Debt should not change during withdrawal
        if(userDebt != userDebtBefore){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Clean up for gas refund if position is closed
        if(userDebt == 0 && s_stakerCollaterals[msg.sender][asset] == 0){
            delete s_stakerCollaterals[msg.sender][asset];
        }

        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to mint
    // @Kevin user can only mint up to theirself collateral value / MINT_RISK_RATIO
    // @Kevin Follow FREI-PI Standard
    function mintSyntheticAsset(address synAsset, uint256 amount) external nonReentrant{
        // F: Function Requirements
        if(!s_supportedSyntheticAssets[synAsset]){
            revert CollateralManager__UnsupportedSyntheticAsset();
        }
        if(amount == 0){
            revert CollateralManager__ZeroAmount();
        }

        // E: Effects - Calculate and validate
        uint256 userDebtBefore = s_debtPool.getUserDebt(msg.sender);
        uint256 userCollateralBefore = getUserCollateralUSD(msg.sender);
        uint256 increasedDebt = uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset())) * amount / 1e18;
        uint256 expectedNewDebt = userDebtBefore + increasedDebt;
        // check if health factor is above MINT_RISK_RATIO after minting
        if(userCollateralBefore * DECIMAL_PRECISION / expectedNewDebt < MINT_RISK_RATIO){
            revert CollateralManager__InsufficientCollateral();
        }

        // I: Interactions
        s_debtPool.increaseDebt(msg.sender, increasedDebt);
        ISynAsset(synAsset).mint(msg.sender, amount);

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebt(msg.sender);
        uint256 userCollateralAfter = getUserCollateralUSD(msg.sender);
        // PI-1: Debt must increase by exact amount
        if(userDebtAfter != userDebtBefore + increasedDebt){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-2: Collateral should remain stable (allowing for oracle price updates)
        // To prevent manipulation, we allow a small tolerance of 5%
        if(userCollateralAfter < userCollateralBefore * 95 / 100){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Health factor must stay above MINT_RISK_RATIO
        if(userCollateralAfter * DECIMAL_PRECISION / userDebtAfter < MINT_RISK_RATIO){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-4: User must remain over-collateralized
        if(userCollateralAfter <= userDebtAfter){
            revert CollateralManager__ProtocolInvariantViolated();
        }

        emit SyntheticAssetMinted(msg.sender, synAsset, amount);
    }

    // @param synAsset: synthetic asset address
    // @param amount: amount of synthetic asset to burn
    // @Kevin user can only burn up to theirself debt amount
    // @Kevin Follow FREI-PI Standard
    function burnSyntheticAsset(address synAsset, uint256 amount) external nonReentrant{
        // F: Function Requirements
        if(!s_supportedSyntheticAssets[synAsset]){
            revert CollateralManager__UnsupportedSyntheticAsset();
        }
        if(amount == 0){
            revert CollateralManager__ZeroAmount();
        }
        
        // E: Effects
        uint256 userDebtBefore = s_debtPool.getUserDebt(msg.sender);
        uint256 decreasedDebt = uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset())) * amount / 1e18;
        // If user tries to burn more than their debt, adjust the amount to burn only their debt
        if(decreasedDebt > userDebtBefore){
            decreasedDebt = userDebtBefore;
            amount = (decreasedDebt * 1e18) / uint256(s_priceOracle.getPrice(ISynAsset(synAsset).representativeAsset()));
        }

        // I: Interactions
        s_debtPool.decreaseDebt(msg.sender, decreasedDebt);
        ISynAsset(synAsset).burn(msg.sender, amount);

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebt(msg.sender);
        // PI-1: Debt must decrease correctly (or become zero)
        if(userDebtAfter != (userDebtBefore >= decreasedDebt ? userDebtBefore - decreasedDebt : 0)){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-2: Debt should never increase (underflow protection)
        if(userDebtAfter > userDebtBefore){
            revert CollateralManager__ProtocolInvariantViolated();
        }

        emit SyntheticAssetBurned(msg.sender, synAsset, amount);
    }

    // @param user: the user to be liquidated
    // @param amount: amount of debt to liquidate in USD
    // @Kevin liquidator will receive collateral + bonus. sUSD will be used to settle the debt
    // @Kevin I want liquidator to share some profit to the staker by swaping other synthetic assets to sUSD later.
    // @Kevin Follow FREI-PI Standard
    function liquidate(address user, uint256 amount) external nonReentrant{
        // F: Function Requirements
        uint256 userDebtBefore = s_debtPool.getUserDebt(user);
        uint256 userCollateralBefore = getUserCollateralUSD(user);
        if(userDebtBefore == 0 || userCollateralBefore * DECIMAL_PRECISION / userDebtBefore >= LIQUIDATION_THRESHOLD){
            revert CollateralManager__HealthyPosition();
        }

        // E: Effects - Calculate liquidation parameters
        uint256 maxDebtToLiquidate = userDebtBefore - (userCollateralBefore * DECIMAL_PRECISION / LIQUIDATION_RISK_RATIO);
        uint256 debtToLiquidate = amount > maxDebtToLiquidate ? maxDebtToLiquidate : amount;

        // I: Interactions - Liquidation based on the proportion of each collateral asset
        for(uint i = 0; i < s_supportedAssetsList.length; ++i){
            address asset = s_supportedAssetsList[i];
            uint256 assetCollateral = s_stakerCollaterals[user][asset];
            if(assetCollateral == 0){
                continue;
            }
            uint256 assetValueUSD = (assetCollateral * uint256(s_priceOracle.getPrice(asset))) / 1e18;
            uint256 liquidateAmountUSD = ((assetValueUSD * DECIMAL_PRECISION / userCollateralBefore) * debtToLiquidate) / DECIMAL_PRECISION;
            uint256 bonusAmountUSD = (liquidateAmountUSD * LIQUIDATION_BONUS) / DECIMAL_PRECISION;
            uint256 totalPayoutAsset = (liquidateAmountUSD + bonusAmountUSD) * DECIMAL_PRECISION / uint256(s_priceOracle.getPrice(asset));

            // Transfer collateral asset to liquidator
            s_stakerCollaterals[user][asset] -= totalPayoutAsset;
            IERC20(asset).safeTransfer(msg.sender, totalPayoutAsset);

            // Burn sUSD from liquidator and decrease user debt
            ISynAsset(i_sUSD).burn(msg.sender, liquidateAmountUSD);
            s_debtPool.decreaseDebt(user, liquidateAmountUSD);
        }

        // PI: Protocol Invariants
        uint256 userDebtAfter = s_debtPool.getUserDebt(user);
        uint256 userCollateralAfter = getUserCollateralUSD(user);
        // PI-1: User debt must decrease
        if(userDebtAfter >= userDebtBefore){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-2: User collateral must decrease
        if(userCollateralAfter >= userCollateralBefore){
            revert CollateralManager__ProtocolInvariantViolated();
        }
        // PI-3: Health factor must improve after liquidation
        uint256 healthFactorBefore = userCollateralBefore * DECIMAL_PRECISION / userDebtBefore;
        uint256 healthFactorAfter = userDebtAfter > 0 
            ? userCollateralAfter * DECIMAL_PRECISION / userDebtAfter 
            : type(uint256).max;
        if(healthFactorAfter <= healthFactorBefore){
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

    function getUserHealthFactor(address user) public view returns (uint256){
        uint256 userDebt = s_debtPool.getUserDebt(user);
        if(userDebt == 0) return type(uint256).max;
        uint256 userCollateral = getUserCollateralUSD(user);
        return userCollateral * DECIMAL_PRECISION / userDebt;
    }
}