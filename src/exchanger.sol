//     ▄▄▄▄                                           ▄▄▄▄▄▄                        ▄▄                           
//   ██▀▀▀▀█                                          ██▀▀▀▀██                      ██                    ██     
//  ██▀        ▄████▄   ▄▄█████▄  ████▄██▄   ▄████▄   ██    ██   ▄█████▄  ▄▄█████▄  ██ ▄██▀    ▄████▄   ███████  
//  ██        ██▀  ▀██  ██▄▄▄▄ ▀  ██ ██ ██  ██▀  ▀██  ███████    ▀ ▄▄▄██  ██▄▄▄▄ ▀  ██▄██     ██▄▄▄▄██    ██     
//  ██▄       ██    ██   ▀▀▀▀██▄  ██ ██ ██  ██    ██  ██    ██  ▄██▀▀▀██   ▀▀▀▀██▄  ██▀██▄    ██▀▀▀▀▀▀    ██     
//   ██▄▄▄▄█  ▀██▄▄██▀  █▄▄▄▄▄██  ██ ██ ██  ▀██▄▄██▀  ██▄▄▄▄██  ██▄▄▄███  █▄▄▄▄▄██  ██  ▀█▄   ▀██▄▄▄▄█    ██▄▄▄  
//     ▀▀▀▀     ▀▀▀▀     ▀▀▀▀▀▀   ▀▀ ▀▀ ▀▀    ▀▀▀▀    ▀▀▀▀▀▀▀    ▀▀▀▀ ▀▀   ▀▀▀▀▀▀   ▀▀   ▀▀▀    ▀▀▀▀▀      ▀▀▀▀  
                                                                                                              
// Author: Kevin Lee
// Date: 2025-11-9
// Description: Exchanger Contract for Synthetic Assets

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";
import {CollateralManager} from "./collateralManager.sol";

contract Exchanger is CollateralManager {

    uint256 public constant EXCHANGE_FEE_RATE = 5E16; // 0.5% fee

    error Exchanger__UnsupportedSyntheticAsset();
    error Exchanger__NonZeroAmount();

    constructor(
        address priceOracleAddress,
        address debtPoolAddress,
        address sUSD,
        address[] memory supportedAssets,
        address[] memory supportedSyntheticAssets
    ) CollateralManager(priceOracleAddress, debtPoolAddress, sUSD, supportedAssets, supportedSyntheticAssets) {}

    modifier supportedAssetsOnly(ISynAsset asset){
        if(!isSyntheticAssetSupported(address(asset))){
            revert Exchanger__UnsupportedSyntheticAsset();
        }
        _;
    }

    modifier nonZeroAmount(uint256 amount){
        if(amount == 0){
            revert Exchanger__NonZeroAmount();
        }
        _;
    }

    function exchangeSynAssetExactInput(
        address from,
        address to,
        uint256 amountIn
    ) public nonZeroAmount(amountIn)  returns (uint256) {
        return _exchangeSynAsset(ISynAsset(from), ISynAsset(to), int256(amountIn));
    }

    function exchangeSynAssetExactOutput(
        address from,
        address to,
        uint256 amountOut
    ) public nonZeroAmount(amountOut) returns (uint256) {
        return _exchangeSynAsset(ISynAsset(from), ISynAsset(to), -int256(amountOut));
    }

    function _exchangeSynAsset(
        ISynAsset from,
        ISynAsset to,
        int256 amount
    ) internal supportedAssetsOnly(from) supportedAssetsOnly(to) returns (uint256) {
        uint256 fromPrice = uint256(s_priceOracle.getPrice(from.representativeAsset()));
        uint256 toPrice = uint256(s_priceOracle.getPrice(to.representativeAsset()));

        if(amount > 0){
            // exchange exact input
            uint256 amountIn = uint256(amount);
            uint256 amountInValueUSD = (amountIn * fromPrice) / DECIMAL_PRECISION;
            uint256 feeUSD = _calculateExchangeFee(amountInValueUSD);
            uint256 amountOutValueUSD = amountInValueUSD - feeUSD;
            uint256 amountOut = (amountOutValueUSD * DECIMAL_PRECISION) / toPrice;

            // infinity liquidity, no any slippage
            // the from asset will be charged fees, and distributed to stakers in the debt pool
            from.burn(msg.sender, amountIn);
            to.mint(msg.sender, amountOut);
            IDebtPool(s_debtPool).distributeRewards(feeUSD);
            return amountOut;
        } else {
            // exchange exact output
            uint256 amountOut = uint256(-amount);
            uint256 amountOutValueUSD = (amountOut * toPrice) / DECIMAL_PRECISION;
            uint256 feeUSD = _calculateExchangeFee(amountOutValueUSD);
            uint256 amountInValueUSD = amountOutValueUSD + feeUSD;
            uint256 amountIn = (amountInValueUSD * DECIMAL_PRECISION) / fromPrice;

            // infinity liquidity, no any slippage
            // the from asset will be charged fees, and distributed to stakers in the debt pool
            from.burn(msg.sender, amountIn);
            to.mint(msg.sender, amountOut);
            IDebtPool(s_debtPool).distributeRewards(feeUSD);
            return amountIn;
        }
    }

    function _calculateExchangeFee(uint256 amount) internal pure returns (uint256) {
        return (amount * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;
    }
}