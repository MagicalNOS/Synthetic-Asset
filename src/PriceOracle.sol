//     ▄▄▄▄                                           ▄▄▄▄▄▄                        ▄▄
//   ██▀▀▀▀█                                          ██▀▀▀▀██                      ██                    ██
//  ██▀        ▄████▄   ▄▄█████▄  ████▄██▄   ▄████▄   ██    ██   ▄█████▄  ▄▄█████▄  ██ ▄██▀    ▄████▄   ███████
//  ██        ██▀  ▀██  ██▄▄▄▄ ▀  ██ ██ ██  ██▀  ▀██  ███████    ▀ ▄▄▄██  ██▄▄▄▄ ▀  ██▄██     ██▄▄▄▄██    ██
//  ██▄       ██    ██   ▀▀▀▀██▄  ██ ██ ██  ██    ██  ██    ██  ▄██▀▀▀██   ▀▀▀▀██▄  ██▀██▄    ██▀▀▀▀▀▀    ██
//   ██▄▄▄▄█  ▀██▄▄██▀  █▄▄▄▄▄██  ██ ██ ██  ▀██▄▄██▀  ██▄▄▄▄██  ██▄▄▄███  █▄▄▄▄▄██  ██  ▀█▄   ▀██▄▄▄▄█    ██▄▄▄
//     ▀▀▀▀     ▀▀▀▀     ▀▀▀▀▀▀   ▀▀ ▀▀ ▀▀    ▀▀▀▀    ▀▀▀▀▀▀▀    ▀▀▀▀ ▀▀   ▀▀▀▀▀▀   ▀▀   ▀▀▀    ▀▀▀▀▀      ▀▀▀▀

// Author: Kevin Lee
// Date: 2025-11-6
// Description: Price Oracle Contract using Chainlink Feeds

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceOracle {
    error PriceOracle__MismatchedArrays();
    error PriceOracle__NegativeOrZeroPrice();
    constructor(address[] memory assets, address[] memory feeds, address sUSD) {
        if (assets.length != feeds.length) {
            revert PriceOracle__MismatchedArrays();
        }
        for (uint256 i = 0; i < assets.length; i++) {
            s_priceOracles[assets[i]] = feeds[i];
        }
        s_sUSD = sUSD;
    }
    // asset address(non USD) => price feed address
    mapping(address => address) public s_priceOracles;
    mapping(address => bool) public s_isInvertAsset;
    // invert asset 18 decimals
    mapping(address => uint256) public s_invertAssetToEntryPrice;
    address public s_sUSD;

    function getPrice(address asset) public view returns (int256) {
        // sUSD is the stablecoin, its price is always $1
        if (asset == s_sUSD) {
            return 1e18;
        }

        if(s_isInvertAsset[asset]) {
            return _getInvertAssetPrice(asset);
        }

        address feed = s_priceOracles[asset];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) {
            revert PriceOracle__NegativeOrZeroPrice();
        }

        uint8 decimals = priceFeed.decimals();
        if (decimals < 18) {
            price = price * int256(10 ** (18 - decimals));
        } else if (decimals > 18) {
            price = price / int256(10 ** (decimals - 18));
        }

        return price;
    }

    function _getInvertAssetPrice(address asset) internal view returns (int256) {
        uint256 entryPrice = s_invertAssetToEntryPrice[asset];
        if (entryPrice == 0) {
            revert PriceOracle__NegativeOrZeroPrice();
        }
        address priceFeed = s_priceOracles[asset];
        AggregatorV3Interface priceFeedInterface = AggregatorV3Interface(priceFeed);
        (, int256 price, , , ) = priceFeedInterface.latestRoundData();
        if (price <= 0) {
            revert PriceOracle__NegativeOrZeroPrice();
        }
        uint8 decimals = priceFeedInterface.decimals();
        if (decimals < 18) {
            price = price * int256(10 ** (18 - decimals));
        } else if (decimals > 18) {
            price = price / int256(10 ** (decimals - 18));
        }
        int256 currentPrice = int256(entryPrice) * 2 - price;
        if (currentPrice <= 0) {
            revert PriceOracle__NegativeOrZeroPrice();
        }
        return currentPrice;
    }
}
