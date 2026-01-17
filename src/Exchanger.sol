// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISynAsset} from "./interfaces/ISynAsset.sol";
import {IDebtPool} from "./interfaces/IDebtPool.sol";
import {CollateralManager} from "./CollateralManager.sol";

contract Exchanger {
    uint256 public constant EXCHANGE_FEE_RATE = 5e15; // 0.5% fee
    uint256 public constant DECIMAL_PRECISION = 1e18;

    IPriceOracle public immutable s_priceOracle;
    IDebtPool public immutable s_debtPool;
    address private immutable i_sUSD;

    // mapping(address => bool) private s_supportedSyntheticAssets; // Removed in favor of DebtPool query

    error Exchanger__UnsupportedSyntheticAsset();
    error Exchanger__NonZeroAmount();

    constructor(
        address priceOracleAddress,
        address debtPoolAddress,
        address sUSD
    ) {
        s_priceOracle = IPriceOracle(priceOracleAddress);
        s_debtPool = IDebtPool(debtPoolAddress);
        i_sUSD = sUSD;
    }

    modifier supportedAssetsOnly(ISynAsset asset) {
        if (!s_debtPool.isSynAssetSupported(address(asset))) {
            revert Exchanger__UnsupportedSyntheticAsset();
        }
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) {
            revert Exchanger__NonZeroAmount();
        }
        _;
    }

    function isSyntheticAssetSupported(
        address synAsset
    ) external view returns (bool) {
        return s_debtPool.isSynAssetSupported(synAsset);
    }

    function exchangeSynAssetExactInput(
        address from,
        address to,
        uint256 amountIn,
        address recipient
    ) public nonZeroAmount(amountIn) returns (uint256) {
        return
            _exchangeSynAsset(
                ISynAsset(from),
                ISynAsset(to),
                int256(amountIn),
                recipient
            );
    }

    function exchangeSynAssetExactOutput(
        address from,
        address to,
        uint256 amountOut,
        address recipient
    ) public nonZeroAmount(amountOut) returns (uint256) {
        return
            _exchangeSynAsset(
                ISynAsset(from),
                ISynAsset(to),
                -int256(amountOut),
                recipient
            );
    }

    function _exchangeSynAsset(
        ISynAsset from,
        ISynAsset to,
        int256 amount,
        address recipient
    )
        internal
        supportedAssetsOnly(from)
        supportedAssetsOnly(to)
        returns (uint256)
    {
        uint256 fromPrice = uint256(
            s_priceOracle.getPrice(from.anchorAddress())
        );
        uint256 toPrice = uint256(s_priceOracle.getPrice(to.anchorAddress()));

        if (amount > 0) {
            // exchange exact input
            uint256 amountIn = uint256(amount);
            uint256 amountInValueUSD = (amountIn * fromPrice) /
                DECIMAL_PRECISION;
            uint256 feeUSD = _calculateExchangeFee(amountInValueUSD);
            uint256 amountOutValueUSD = amountInValueUSD - feeUSD;
            uint256 amountOut = (amountOutValueUSD * DECIMAL_PRECISION) /
                toPrice;

            // infinity liquidity, no any slippage
            // the from asset will be charged fees, and distributed to stakers in the debt pool
            from.burn(msg.sender, amountIn);
            to.mint(recipient, amountOut);
            s_debtPool.distributeRewards(feeUSD);
            return amountOut;
        } else {
            // exchange exact output
            uint256 amountOut = uint256(-amount);
            uint256 amountOutValueUSD = (amountOut * toPrice) /
                DECIMAL_PRECISION;
            uint256 feeUSD = _calculateExchangeFee(amountOutValueUSD);
            uint256 amountInValueUSD = amountOutValueUSD + feeUSD;
            uint256 amountIn = (amountInValueUSD * DECIMAL_PRECISION) /
                fromPrice;

            // infinity liquidity, no any slippage
            // the from asset will be charged fees, and distributed to stakers in the debt pool
            from.burn(msg.sender, amountIn);
            to.mint(recipient, amountOut);
            s_debtPool.distributeRewards(feeUSD);
            return amountIn;
        }
    }

    function _calculateExchangeFee(
        uint256 amount
    ) internal pure returns (uint256) {
        return (amount * EXCHANGE_FEE_RATE) / DECIMAL_PRECISION;
    }
}
