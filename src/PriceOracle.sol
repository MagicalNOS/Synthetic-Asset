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
    address public s_sUSD;

    function getPrice(address asset) public view returns (int256) {
        // sUSD is the stablecoin, its price is always $1
        if (asset == s_sUSD) {
            return 1e18;
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
}
