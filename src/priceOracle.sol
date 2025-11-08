                                                                                      
                                                                                                              
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

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceOracle {
    address private immutable i_btcAddress;
    address private immutable i_usdcAddres;
    error PriceOracle__MismatchedArrays();
    error PriceOracle__NegativeOrZeroPrice();
    constructor(address[] memory assets, address[] memory feeds, address btcAddress, address usdcAddress){
        if(assets.length != feeds.length){
            revert PriceOracle__MismatchedArrays();
        }
        i_btcAddress = btcAddress;
        i_usdcAddres = usdcAddress;
        for(uint256 i = 0; i < assets.length; i++){
            s_priceOracles[assets[i]] = feeds[i];
        }
    }
    // asset address(non USD) => price feed address
    mapping (address => address) public s_priceOracles;

    function getPrice(address asset) public view returns (int256){
        address feed = s_priceOracles[asset];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (,int256 price,,,) = priceFeed.latestRoundData();
        if(price <= 0){
            revert PriceOracle__NegativeOrZeroPrice();
        }
        if(asset == i_btcAddress){
            // BTC/USD price feed returns price with 8 decimals
            // We convert it to 18 decimals
            price = price * 1e10;
        }

        if(asset == i_usdcAddres){
            // USDC/USD price feed returns price with 8 decimals
            // We convert it to 18 decimals
            price = price * 1e10;
        }

        return price;
    }
}